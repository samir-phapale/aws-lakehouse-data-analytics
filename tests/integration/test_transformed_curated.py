"""Checks the transformed and curated Delta tables and their Glue catalog entries.

Run after `scripts/run_transformed.sh` and `scripts/run_curated.sh`, with the same bucket
variables as test_raw_layer.py, plus GLUE_DATABASE_PREFIX if it is not lakehouse_dev.
"""

import os

import pytest

DATABASE_PREFIX = os.environ.get("GLUE_DATABASE_PREFIX", "lakehouse_dev")
TRANSFORMED_TABLES = [
    "customers", "sellers", "products", "geolocation", "orders", "order_items", "order_payments",
    "order_reviews", "order_events", "order_status_current", "tpch_customer",
]
CURATED_TABLES = [
    "dim_date", "dim_geography", "dim_customer", "dim_seller", "dim_product",
    "fact_order_items", "fact_orders",
    "agg_daily_sales", "agg_seller_performance", "agg_delivery_performance",
    "agg_review_vs_delivery", "agg_payment_mix", "agg_tpch_customer_segment",
]


def has_objects(s3_client, bucket, prefix):
    return s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1).get("KeyCount", 0) > 0


@pytest.mark.parametrize("table", TRANSFORMED_TABLES)
def test_transformed_table_is_delta(s3_client, bucket, table):
    name = bucket("TRANSFORMED")
    assert has_objects(s3_client, name, f"{table}/_delta_log/"), f"s3://{name}/{table}/ is not a Delta table"


@pytest.mark.parametrize("table", TRANSFORMED_TABLES)
def test_transformed_has_dq_snapshot(s3_client, bucket, table):
    name = bucket("TRANSFORMED")
    assert has_objects(s3_client, name, f"_dq/{table}/"), f"no DataBrew snapshot at s3://{name}/_dq/{table}/"


@pytest.mark.parametrize("table", CURATED_TABLES)
def test_curated_table_is_delta(s3_client, bucket, table):
    name = bucket("CURATED")
    assert has_objects(s3_client, name, f"{table}/_delta_log/"), f"s3://{name}/{table}/ is not a Delta table"


@pytest.mark.parametrize(
    "zone,table",
    [("transformed", t) for t in TRANSFORMED_TABLES] + [("curated", t) for t in CURATED_TABLES],
)
def test_table_in_catalog(glue_client, bucket, zone, table):
    bucket(zone.upper())
    found = glue_client.get_table(DatabaseName=f"{DATABASE_PREFIX}_{zone}", Name=table)["Table"]
    assert found["StorageDescriptor"]["Location"].rstrip("/").endswith(f"/{table}")
