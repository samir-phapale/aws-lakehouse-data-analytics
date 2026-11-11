"""Glue streaming job: append each MSK micro-batch to landing as JSON lines.

Writes s3://<landing>/stream/<topic>/ingest_date=YYYY-MM-DD/; Kafka offsets live in the
checkpoint location, so a restarted job carries on where it stopped.
"""

import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import current_timestamp, date_format

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "CONNECTION_NAME",
        "TOPIC_NAME",
        "LANDING_BUCKET",
        "CHECKPOINT_LOCATION",
        "WINDOW_SIZE",
    ],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

topic = args["TOPIC_NAME"]
target_path = f"s3://{args['LANDING_BUCKET']}/stream/{topic}/"

events = glue_context.create_data_frame.from_options(
    connection_type="kafka",
    connection_options={
        "connectionName": args["CONNECTION_NAME"],
        "topicName": topic,
        "startingOffsets": "earliest",
        "classification": "json",
        "inferSchema": "true",
        # Records removed by retention before we read them should not stop the job
        "failOnDataLoss": "false",
    },
    transformation_ctx="read_msk",
)


def write_batch(batch, batch_id):
    rows = batch.count()
    if rows == 0:
        return
    # With inferSchema the batch holds one raw JSON column; the DynamicFrame round trip applies the schema
    batch = DynamicFrame.fromDF(batch, glue_context, "from_df").toDF()
    # partitionBy puts ingest_date in the folder name only, so the lines hold the producer's fields
    (
        batch.withColumn("ingest_date", date_format(current_timestamp(), "yyyy-MM-dd"))
        .write.mode("append")
        .partitionBy("ingest_date")
        .json(target_path)
    )
    print(f"Batch {batch_id}: appended {rows} events to {target_path}")


glue_context.forEachBatch(
    frame=events,
    batch_function=write_batch,
    options={
        "windowSize": args["WINDOW_SIZE"],
        "checkpointLocation": args["CHECKPOINT_LOCATION"],
    },
)

job.commit()
