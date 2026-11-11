"""Glue job: export each RDS MySQL table over JDBC to landing as CSV (header, source columns only).

Full extract per run to s3://<landing>/rds/<database>/<table>/ingest_date=YYYY-MM-DD/;
a same-day rerun replaces that day's folder.
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "CONNECTION_NAME", "SOURCE_DATABASE", "SOURCE_TABLES", "LANDING_BUCKET"],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

database = args["SOURCE_DATABASE"]
ingest_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")

for table in [t.strip() for t in args["SOURCE_TABLES"].split(",") if t.strip()]:
    # Cached so the row count below does not query MySQL a second time
    frame = glue_context.create_dynamic_frame.from_options(
        connection_type="mysql",
        connection_options={
            "useConnectionProperties": "true",
            "connectionName": args["CONNECTION_NAME"],
            "dbtable": table,
        },
        transformation_ctx=f"read_{table}",
    ).toDF().cache()

    target = f"s3://{args['LANDING_BUCKET']}/rds/{database}/{table}/ingest_date={ingest_date}/"
    # RFC 4180 quoting keeps review comments with line breaks in one field
    (
        frame.write.mode("overwrite")
        .option("header", "true")
        .option("quote", '"')
        .option("escape", '"')
        .option("timestampFormat", "yyyy-MM-dd HH:mm:ss")
        .csv(target)
    )
    print(f"Wrote {frame.count()} rows from {database}.{table} to {target}")
    frame.unpersist()

job.commit()
