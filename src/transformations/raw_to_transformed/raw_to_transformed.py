"""Glue job: rebuild the transformed zone from the latest raw data (--TABLES "all" or a comma list).

Per table writes transformed/<table>/ (Delta), _dq/<table>/ (Parquet for DataBrew) and
_quarantine/<table>/ (rows failing the quality rules, with _dq_reason).
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

import olist_transforms as olist
import quality
import tpch_transforms as tpch
from quality import not_null

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "RAW_BUCKET", "TRANSFORMED_BUCKET", "SOURCE_DATABASE", "TOPIC_NAME", "TABLES"],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# DataBrew reads the _dq/ Parquet copies: it needs folders without _SUCCESS markers and
# microsecond timestamps instead of Spark's legacy INT96
sc._jsc.hadoopConfiguration().set("mapreduce.fileoutputcommitter.marksuccessfuljobs", "false")
spark.conf.set("spark.sql.parquet.outputTimestampType", "TIMESTAMP_MICROS")

raw_root = f"s3://{args['RAW_BUCKET']}/"
out_root = f"s3://{args['TRANSFORMED_BUCKET']}/"
database = args["SOURCE_DATABASE"]
built = {}


def read_delta(path):
    return spark.read.format("delta").load(path)


def raw_latest(path):
    """Each raw batch day is a full extract, so only the newest ingest_date is used."""
    frame = read_delta(f"{raw_root}{path}")
    latest = frame.agg(F.max("ingest_date")).first()[0]
    print(f"{path}: using ingest_date {latest}")
    return frame.filter(F.col("ingest_date") == latest)


def rds(table):
    return raw_latest(f"rds/{database}/{table}/")


def transformed(name):
    """A table built earlier in this run, or the copy already in the transformed zone."""
    if name not in built:
        built[name] = read_delta(f"{out_root}{name}/")
    return built[name]


def flag_reference(frame, column, table):
    flag = f"_ref_{table}"
    return quality.flag_reference(frame, column, transformed(table), column, flag), F.col(flag)


def build_orders():
    frame, customer_found = flag_reference(olist.orders(rds("orders")), "customer_id", "customers")
    return frame, [
        ("order_id_missing", not_null("order_id")),
        ("purchased_at_missing", not_null("purchased_at")),
        ("unknown_status", F.col("order_status").isin(olist.ORDER_STATUSES)),
        ("customer_not_found", customer_found),
    ]


def build_order_items():
    frame = olist.order_items(rds("order_items"))
    frame, order_found = flag_reference(frame, "order_id", "orders")
    frame, product_found = flag_reference(frame, "product_id", "products")
    frame, seller_found = flag_reference(frame, "seller_id", "sellers")
    return frame, [
        ("key_missing", not_null("order_id", "order_item_id")),
        ("negative_price", F.col("price") >= 0),
        ("negative_freight", F.col("freight_value") >= 0),
        ("order_not_found", order_found),
        ("product_not_found", product_found),
        ("seller_not_found", seller_found),
    ]


def build_order_payments():
    frame, order_found = flag_reference(olist.order_payments(rds("order_payments")), "order_id", "orders")
    return frame, [
        ("key_missing", not_null("order_id", "payment_sequential")),
        ("negative_value", F.col("payment_value") >= 0),
        ("order_not_found", order_found),
    ]


def build_order_reviews():
    frame, order_found = flag_reference(olist.order_reviews(rds("order_reviews")), "order_id", "orders")
    return frame, [
        ("key_missing", not_null("review_id", "order_id")),
        ("score_out_of_range", F.col("review_score").between(1, 5)),
        ("order_not_found", order_found),
    ]


def build_order_events():
    # The stream appends small batches every day, so all days are read, not just the latest
    frame = olist.order_events(read_delta(f"{raw_root}stream/{args['TOPIC_NAME']}/"))
    return frame, [
        ("key_missing", not_null("event_id", "order_id")),
        ("event_time_missing", not_null("event_time")),
        ("unknown_event_type", F.col("event_rank").isNotNull()),
    ]


# table -> builder returning (frame, rules); dict order is the dependency order
TABLES = {
    "customers": lambda: (
        olist.customers(rds("customers")),
        [("key_missing", not_null("customer_id", "customer_unique_id"))],
    ),
    "sellers": lambda: (olist.sellers(rds("sellers")), [("key_missing", not_null("seller_id"))]),
    "products": lambda: (
        olist.products(rds("products"), rds("category_translation")),
        [("key_missing", not_null("product_id"))],
    ),
    "geolocation": lambda: (
        olist.geolocation(rds("geolocation")),
        [("key_missing", not_null("zip_code_prefix"))],
    ),
    "orders": build_orders,
    "order_items": build_order_items,
    "order_payments": build_order_payments,
    "order_reviews": build_order_reviews,
    "order_events": build_order_events,
    "order_status_current": lambda: (olist.order_status_current(transformed("order_events")), []),
    "tpch_customer": lambda: (
        tpch.tpch_customer(raw_latest("files/tpch_customer/")),
        [("key_missing", not_null("c_custkey"))],
    ),
}

selected = list(TABLES) if args["TABLES"] == "all" else [t.strip() for t in args["TABLES"].split(",") if t.strip()]
unknown = set(selected) - set(TABLES)
if unknown:
    raise ValueError(f"Unknown tables: {sorted(unknown)}")

for name in [t for t in TABLES if t in selected]:
    frame, rules = TABLES[name]()
    good, quarantined = quality.split(frame, rules)

    target = f"{out_root}{name}/"
    (
        good.withColumn("_processed_at", F.current_timestamp())
        .write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .save(target)
    )
    built[name] = read_delta(target)
    # overwrite also removes the _seed object Terraform puts here for DataBrew
    built[name].write.mode("overwrite").parquet(f"{out_root}_dq/{name}/")
    quarantined.write.mode("overwrite").parquet(f"{out_root}_quarantine/{name}/")

    rejected = spark.read.parquet(f"{out_root}_quarantine/{name}/").count()
    print(f"{name}: {built[name].count()} rows -> {target}, {rejected} quarantined")

job.commit()
