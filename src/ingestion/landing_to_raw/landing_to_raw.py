"""Glue job: promote one day of landing (MySQL CSV exports, stream JSON lines, DataSync files) to raw Delta.

Raw keeps every value as a string plus lineage columns; a rerun replaces only that day's
ingest_date partition (--INGEST_DATE, "today" = current UTC date). With "today" the stream also
catches up: see ingest_days.stream_days.
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import current_timestamp, input_file_name, lit
from pyspark.sql.functions import max as max_

from ingest_days import folder_days, stream_days

# Header-less files get their column names from here (TPC-H spec, dbgen .tbl layout)
KNOWN_COLUMNS = {
    "tpch_customer": [
        "c_custkey", "c_name", "c_address", "c_nationkey",
        "c_phone", "c_acctbal", "c_mktsegment", "c_comment",
    ],
}

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "LANDING_BUCKET",
        "RAW_BUCKET",
        "SOURCES",
        "INGEST_DATE",
        "SOURCE_DATABASE",
        "SOURCE_TABLES",
        "TOPIC_NAME",
        "DATASETS",
        "LANDING_PREFIX",
        "DELTA_PREFIX",
        "SOURCE_FORMAT",
        "CSV_DELIMITER",
        "CSV_HEADER",
    ],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)


def split(value):
    return [v.strip() for v in value.split(",") if v.strip()]


landing = f"s3://{args['LANDING_BUCKET']}/"
raw = f"s3://{args['RAW_BUCKET']}/"
sources = split(args["SOURCES"])
requested_date = args["INGEST_DATE"]
ingest_date = datetime.now(timezone.utc).strftime("%Y-%m-%d") if requested_date == "today" else requested_date


def hadoop_path(path):
    jvm_path = sc._jvm.org.apache.hadoop.fs.Path(path)
    return jvm_path, jvm_path.getFileSystem(sc._jsc.hadoopConfiguration())


def exists(path):
    jvm_path, fs = hadoop_path(path)
    return fs.exists(jvm_path)


def subfolders(path):
    if not exists(path):
        return []
    jvm_path, fs = hadoop_path(path)
    return [status.getPath().toString() for status in fs.listStatus(jvm_path) if status.isDirectory()]


def csv_reader(header, delimiter=","):
    # RFC 4180 quoting and quoted line breaks (review comments); no schema inference, raw keeps strings
    return (
        spark.read.option("header", header)
        .option("sep", delimiter)
        .option("quote", '"')
        .option("escape", '"')
        .option("multiLine", "true")
    )


def write_raw(frame, source, target, day=ingest_date):
    this_day = f"ingest_date = '{day}'"
    now = current_timestamp()
    (
        frame.withColumn("_source_file", input_file_name())
        .withColumn("_ingested_at", now)
        .withColumn("_source", lit(source))
        .withColumn("_raw_loaded_at", now)
        .withColumn("ingest_date", lit(day))
        .write.format("delta")
        .mode("overwrite")
        .option("replaceWhere", this_day)
        .option("mergeSchema", "true")
        .partitionBy("ingest_date")
        .save(target)
    )
    # Counting the written partition reads Parquet instead of parsing the source files again
    rows = spark.read.format("delta").load(target).where(this_day).count()
    print(f"Wrote {rows} rows to Delta table {target} ({this_day})")


def day_folder(landing_table, day=ingest_date):
    """The landing folder for one day, or None if nothing landed."""
    path = f"{landing}{landing_table}ingest_date={day}/"
    if exists(path):
        return path
    print(f"Skipping {landing_table}: nothing landed for {day}")
    return None


def latest_raw_day(target):
    if not exists(f"{target}_delta_log/"):
        return None
    return spark.read.format("delta").load(target).agg(max_("ingest_date")).first()[0]


def read_files(dataset, path):
    source_format = args["SOURCE_FORMAT"].lower()
    if source_format == "csv":
        frame = csv_reader(args["CSV_HEADER"].lower(), args["CSV_DELIMITER"]).csv(path)
    else:
        frame = spark.read.format(source_format).load(path)
    names = KNOWN_COLUMNS.get(dataset)
    if names and frame.columns[0] == "_c0":
        # dbgen ends every line with the delimiter, which reads as one extra empty column
        frame = frame.select(*frame.columns[: len(names)]).toDF(*names)
    # Some exports start with a UTF-8 byte order mark that ends up in the first column name
    return frame.toDF(*[c.lstrip("﻿") for c in frame.columns])


if "rds" in sources:
    database = args["SOURCE_DATABASE"]
    for table in split(args["SOURCE_TABLES"]):
        folder = day_folder(f"rds/{database}/{table}/")
        if folder:
            write_raw(csv_reader("true").csv(folder), f"rds-mysql/{database}/{table}", f"{raw}rds/{database}/{table}/")

if "stream" in sources:
    topic = args["TOPIC_NAME"]
    target = f"{raw}stream/{topic}/"
    landed = folder_days(subfolders(f"{landing}stream/{topic}/"))
    days = stream_days(landed, latest_raw_day(target), requested_date)
    print(f"Stream days to promote: {days or 'none'}")
    for day in days:
        folder = day_folder(f"stream/{topic}/", day)
        if folder:
            # primitivesAsString keeps event values as strings, like every other raw table
            events = spark.read.option("primitivesAsString", "true").json(folder)
            write_raw(events, f"msk/{topic}", target, day)

if "files" in sources:
    # DataSync keeps the latest delivery in place (no date folders); each run snapshots it
    for dataset in split(args["DATASETS"]):
        source = f"{landing}{args['LANDING_PREFIX']}{dataset}/"
        if not exists(source):
            print(f"Skipping files/{dataset}: nothing in landing")
            continue
        write_raw(read_files(dataset, source), f"s3-files/{dataset}", f"{raw}{args['DELTA_PREFIX']}{dataset}/")

job.commit()
