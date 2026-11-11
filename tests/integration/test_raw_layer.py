"""Checks the deployed zone buckets, what arrived in landing, and the raw Delta tables.

Run after `scripts/run_raw_ingestion.sh` and `scripts/run_stream_ingestion.sh`:
    tf() { terraform -chdir=infrastructure/terraform output -raw "$1"; }
    LANDING_BUCKET=$(tf landing_bucket_name) RAW_BUCKET=$(tf raw_bucket_name) \
    TRANSFORMED_BUCKET=$(tf transformed_bucket_name) CURATED_BUCKET=$(tf curated_bucket_name) \
        pytest tests/integration
"""

import os

import pytest

MYSQL_DATABASE = os.environ.get("MYSQL_DATABASE", "salesdb")
MYSQL_TABLES = os.environ.get(
    "MYSQL_TABLES",
    "customers,orders,order_items,order_payments,products,sellers,"
    "order_reviews,geolocation,category_translation",
).split(",")
FILE_DATASETS = os.environ.get("FILE_DATASETS", "tpch_customer").split(",")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "order_events")
ZONES = ["LANDING", "RAW", "TRANSFORMED", "CURATED"]


def list_keys(s3_client, bucket, prefix):
    paginator = s3_client.get_paginator("list_objects_v2")
    return [
        obj["Key"]
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix)
        for obj in page.get("Contents", [])
    ]


def assert_delta_table(s3_client, bucket, table_prefix):
    log = list_keys(s3_client, bucket, f"{table_prefix}_delta_log/")
    assert any(k.endswith(".json") for k in log), f"no Delta commit log under {table_prefix}"
    data = list_keys(s3_client, bucket, f"{table_prefix}ingest_date=")
    assert any(k.endswith(".parquet") for k in data), f"no data files under {table_prefix}"


def assert_landed(s3_client, bucket, prefix, extension):
    keys = list_keys(s3_client, bucket, prefix)
    assert any(k.endswith(extension) for k in keys), f"no {extension} files under {prefix}"


@pytest.mark.parametrize("zone", ZONES)
def test_bucket_uses_kms(s3_client, bucket, zone):
    encryption = s3_client.get_bucket_encryption(Bucket=bucket(zone))
    rules = encryption["ServerSideEncryptionConfiguration"]["Rules"]
    assert rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms"


@pytest.mark.parametrize("zone", ZONES)
def test_bucket_blocks_public_access(s3_client, bucket, zone):
    config = s3_client.get_public_access_block(Bucket=bucket(zone))["PublicAccessBlockConfiguration"]
    assert all(config.values()), config


@pytest.mark.parametrize("table", MYSQL_TABLES)
def test_rds_table_landed(s3_client, bucket, table):
    assert_landed(s3_client, bucket("LANDING"), f"rds/{MYSQL_DATABASE}/{table}/ingest_date=", ".csv")


def test_stream_topic_landed(s3_client, bucket):
    assert_landed(s3_client, bucket("LANDING"), f"stream/{KAFKA_TOPIC}/ingest_date=", ".json")


@pytest.mark.parametrize("dataset", FILE_DATASETS)
def test_datasync_files_landed(s3_client, bucket, dataset):
    assert list_keys(s3_client, bucket("LANDING"), f"files/{dataset}/"), f"DataSync delivered no files for {dataset}"


@pytest.mark.parametrize("table", MYSQL_TABLES)
def test_rds_table_is_delta(s3_client, bucket, table):
    assert_delta_table(s3_client, bucket("RAW"), f"rds/{MYSQL_DATABASE}/{table}/")


@pytest.mark.parametrize("dataset", FILE_DATASETS)
def test_file_dataset_is_delta(s3_client, bucket, dataset):
    assert_delta_table(s3_client, bucket("RAW"), f"files/{dataset}/")


def test_stream_topic_is_delta(s3_client, bucket):
    assert_delta_table(s3_client, bucket("RAW"), f"stream/{KAFKA_TOPIC}/")
