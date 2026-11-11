"""Row-level quality rules: split a table into rows that pass and rows to quarantine.

A rule is (name, condition) with the condition True for a good row; a null result counts as a
failure. Table-level checks (completeness, uniqueness, ranges) are left to DataBrew.
"""

from functools import reduce

from pyspark.sql import DataFrame
from pyspark.sql import functions as F


def not_null(*columns):
    return reduce(lambda a, b: a & b, [F.col(c).isNotNull() for c in columns])


def flag_reference(frame: DataFrame, column: str, ref: DataFrame, ref_column: str, flag: str) -> DataFrame:
    """Adds boolean column `flag`: True when frame.column exists in ref.ref_column."""
    keys = ref.select(F.col(ref_column).alias("_ref_key")).distinct().withColumn(flag, F.lit(True))
    return (
        frame.join(keys, frame[column] == keys["_ref_key"], "left")
        .drop("_ref_key")
        .withColumn(flag, F.coalesce(F.col(flag), F.lit(False)))
    )


def split(frame: DataFrame, rules):
    """Returns (good, quarantined); quarantined rows get `_dq_reason`, `_ref_*` columns are dropped."""
    failed = [F.when(~F.coalesce(condition, F.lit(False)), F.lit(name)) for name, condition in rules]
    checked = frame.withColumn("_dq_reason", F.concat_ws(",", *failed) if failed else F.lit(""))
    checked = checked.drop(*[c for c in checked.columns if c.startswith("_ref_")])
    good = checked.filter(F.col("_dq_reason") == "").drop("_dq_reason")
    quarantined = checked.filter(F.col("_dq_reason") != "")
    return good, quarantined
