"""Raw -> transformed rules for the TPC-H customer file (raw keeps every column as a string)."""

from pyspark.sql import DataFrame
from pyspark.sql import functions as F


def tpch_customer(raw: DataFrame) -> DataFrame:
    return raw.select(
        F.trim("c_custkey").cast("bigint").alias("c_custkey"),
        F.trim("c_name").alias("c_name"),
        F.trim("c_address").alias("c_address"),
        F.trim("c_nationkey").cast("int").alias("c_nationkey"),
        F.trim("c_phone").alias("c_phone"),
        F.trim("c_acctbal").cast("decimal(15,2)").alias("c_acctbal"),
        F.upper(F.trim("c_mktsegment")).alias("c_mktsegment"),
        F.trim("c_comment").alias("c_comment"),
        "_ingested_at",
        "_source",
    ).dropDuplicates(["c_custkey"])
