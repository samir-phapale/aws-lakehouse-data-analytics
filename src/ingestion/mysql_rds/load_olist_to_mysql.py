"""Glue job: full reload of the Olist CSVs from S3 into the private RDS MySQL source over JDBC.

Reads s3://<source-files>/<LOAD_PREFIX><table>.csv per table and recreates the MySQL table.
"""

import json
import sys

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

args = getResolvedOptions(
    sys.argv, ["JOB_NAME", "JDBC_URL", "SECRET_ARN", "SOURCE_BUCKET", "LOAD_PREFIX", "TABLES"]
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# MySQL column types; ids are 32-char hashes, zip prefixes stay strings to keep leading zeros
SCHEMAS = {
    "customers": [
        ("customer_id", "CHAR(32)"),
        ("customer_unique_id", "CHAR(32)"),
        ("customer_zip_code_prefix", "CHAR(5)"),
        ("customer_city", "VARCHAR(64)"),
        ("customer_state", "CHAR(2)"),
    ],
    "orders": [
        ("order_id", "CHAR(32)"),
        ("customer_id", "CHAR(32)"),
        ("order_status", "VARCHAR(16)"),
        ("order_purchase_timestamp", "TIMESTAMP"),
        ("order_approved_at", "TIMESTAMP"),
        ("order_delivered_carrier_date", "TIMESTAMP"),
        ("order_delivered_customer_date", "TIMESTAMP"),
        ("order_estimated_delivery_date", "TIMESTAMP"),
    ],
    "order_items": [
        ("order_id", "CHAR(32)"),
        ("order_item_id", "INT"),
        ("product_id", "CHAR(32)"),
        ("seller_id", "CHAR(32)"),
        ("shipping_limit_date", "TIMESTAMP"),
        ("price", "DECIMAL(10,2)"),
        ("freight_value", "DECIMAL(10,2)"),
    ],
    "order_payments": [
        ("order_id", "CHAR(32)"),
        ("payment_sequential", "INT"),
        ("payment_type", "VARCHAR(16)"),
        ("payment_installments", "INT"),
        ("payment_value", "DECIMAL(10,2)"),
    ],
    # Column names keep Olist's spelling ("lenght"); silver renames them
    "products": [
        ("product_id", "CHAR(32)"),
        ("product_category_name", "VARCHAR(64)"),
        ("product_name_lenght", "INT"),
        ("product_description_lenght", "INT"),
        ("product_photos_qty", "INT"),
        ("product_weight_g", "INT"),
        ("product_length_cm", "INT"),
        ("product_height_cm", "INT"),
        ("product_width_cm", "INT"),
    ],
    "sellers": [
        ("seller_id", "CHAR(32)"),
        ("seller_zip_code_prefix", "CHAR(5)"),
        ("seller_city", "VARCHAR(64)"),
        ("seller_state", "CHAR(2)"),
    ],
    # review_id alone is not unique; (review_id, order_id) is. Comments contain line breaks.
    "order_reviews": [
        ("review_id", "CHAR(32)"),
        ("order_id", "CHAR(32)"),
        ("review_score", "INT"),
        ("review_comment_title", "VARCHAR(64)"),
        ("review_comment_message", "TEXT"),
        ("review_creation_date", "TIMESTAMP"),
        ("review_answer_timestamp", "TIMESTAMP"),
    ],
    "geolocation": [
        ("geolocation_zip_code_prefix", "CHAR(5)"),
        ("geolocation_lat", "DOUBLE"),
        ("geolocation_lng", "DOUBLE"),
        ("geolocation_city", "VARCHAR(64)"),
        ("geolocation_state", "CHAR(2)"),
    ],
    "category_translation": [
        ("product_category_name", "VARCHAR(64)"),
        ("product_category_name_english", "VARCHAR(64)"),
    ],
}

secret = json.loads(
    boto3.client("secretsmanager").get_secret_value(SecretId=args["SECRET_ARN"])["SecretString"]
)
jdbc_url = f"{args['JDBC_URL']}?sslMode=REQUIRED&rewriteBatchedStatements=true&characterEncoding=UTF-8"
jdbc_properties = {
    "user": secret["username"],
    "password": secret["password"],
    "driver": "com.mysql.cj.jdbc.Driver",
}


def spark_type(mysql_type):
    # Widths only matter on the MySQL side (createTableColumnTypes); Spark writes strings as TEXT
    return "STRING" if mysql_type.startswith(("CHAR", "VARCHAR", "TEXT")) else mysql_type


for table in [t.strip() for t in args["TABLES"].split(",") if t.strip()]:
    columns = SCHEMAS[table]
    frame = (
        spark.read.option("header", "true")
        .option("quote", '"')
        .option("escape", '"')
        .option("multiLine", "true")
        .option("timestampFormat", "yyyy-MM-dd HH:mm:ss")
        .schema(", ".join(f"{name} {spark_type(kind)}" for name, kind in columns))
        .csv(f"s3://{args['SOURCE_BUCKET']}/{args['LOAD_PREFIX']}{table}.csv")
    )
    (
        frame.write.mode("overwrite")
        .option("createTableColumnTypes", ", ".join(f"{n} {k}" for n, k in columns if "CHAR" in k))
        .option("createTableOptions", "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        .option("batchsize", "5000")
        .jdbc(url=jdbc_url, table=table, properties=jdbc_properties)
    )
    print(f"Loaded {frame.count()} rows into {table}")

job.commit()
