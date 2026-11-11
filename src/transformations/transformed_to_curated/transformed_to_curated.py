"""Glue job: rebuild the curated zone (star schema + aggregates) from the transformed Delta tables.

--TABLES "all" or a comma list; each table is a full Delta overwrite of curated/<table>/.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

import curated_transforms as c

args = getResolvedOptions(sys.argv, ["JOB_NAME", "TRANSFORMED_BUCKET", "CURATED_BUCKET", "TABLES"])

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

in_root = f"s3://{args['TRANSFORMED_BUCKET']}/"
out_root = f"s3://{args['CURATED_BUCKET']}/"
inputs = {}
built = {}


def read_delta(path):
    return spark.read.format("delta").load(path)


def transformed(name):
    if name not in inputs:
        inputs[name] = read_delta(f"{in_root}{name}/")
    return inputs[name]


def curated(name):
    """A table built earlier in this run, or the copy already in the curated zone."""
    if name not in built:
        built[name] = read_delta(f"{out_root}{name}/")
    return built[name]


# dict order is the dependency order
TABLES = {
    "dim_date": lambda: c.dim_date(transformed("orders")),
    "dim_geography": lambda: c.dim_geography(transformed("geolocation")),
    "dim_customer": lambda: c.dim_customer(transformed("customers"), transformed("orders")),
    "dim_seller": lambda: c.dim_seller(transformed("sellers"), transformed("geolocation")),
    "dim_product": lambda: c.dim_product(transformed("products")),
    "fact_order_items": lambda: c.fact_order_items(
        transformed("order_items"), transformed("orders"), transformed("customers")
    ),
    "fact_orders": lambda: c.fact_orders(
        transformed("orders"),
        transformed("customers"),
        transformed("order_items"),
        transformed("order_payments"),
        transformed("order_reviews"),
    ),
    "agg_daily_sales": lambda: c.agg_daily_sales(curated("fact_order_items"), transformed("products")),
    "agg_seller_performance": lambda: c.agg_seller_performance(curated("fact_order_items"), curated("fact_orders")),
    "agg_delivery_performance": lambda: c.agg_delivery_performance(curated("fact_order_items"), transformed("sellers")),
    "agg_review_vs_delivery": lambda: c.agg_review_vs_delivery(curated("fact_orders")),
    "agg_payment_mix": lambda: c.agg_payment_mix(transformed("order_payments")),
    "agg_tpch_customer_segment": lambda: c.agg_tpch_customer_segment(transformed("tpch_customer")),
}

selected = list(TABLES) if args["TABLES"] == "all" else [t.strip() for t in args["TABLES"].split(",") if t.strip()]
unknown = set(selected) - set(TABLES)
if unknown:
    raise ValueError(f"Unknown tables: {sorted(unknown)}")

for name in [t for t in TABLES if t in selected]:
    target = f"{out_root}{name}/"
    (
        TABLES[name]()
        .withColumn("_processed_at", F.current_timestamp())
        .write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .save(target)
    )
    built[name] = read_delta(target)
    print(f"{name}: {built[name].count()} rows -> {target}")

job.commit()
