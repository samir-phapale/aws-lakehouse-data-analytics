"""Local Spark session and table builders for the transformation unit tests (skipped without pyspark).

Test tables are built with SQL VALUES, which runs in the JVM only: Python worker processes
crash on some Windows setups.
"""

import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pytest

TRANSFORMATIONS = Path(__file__).resolve().parents[2] / "src" / "transformations"
sys.path.insert(0, str(TRANSFORMATIONS / "raw_to_transformed"))
sys.path.insert(0, str(TRANSFORMATIONS / "transformed_to_curated"))

pytest.importorskip("pyspark")
from pyspark.sql import SparkSession  # noqa: E402

INGESTED = datetime(2026, 11, 3, 12, 0, 0)


@pytest.fixture(scope="session")
def spark():
    session = (
        SparkSession.builder.master("local[1]")
        .appName("transform-unit-tests")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .getOrCreate()
    )
    yield session
    session.stop()


def sql_literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, datetime):
        return f"TIMESTAMP'{value:%Y-%m-%d %H:%M:%S}'"
    if isinstance(value, date):
        return f"DATE'{value:%Y-%m-%d}'"
    if isinstance(value, Decimal):
        return f"CAST('{value}' AS DECIMAL(10,2))"
    if isinstance(value, (int, float)):
        return repr(value)
    escaped = str(value).replace("\\", "\\\\").replace("'", "\\'").replace("\r", "\\r").replace("\n", "\\n")
    return f"'{escaped}'"


def values_frame(spark, rows, columns):
    body = ", ".join("(" + ", ".join(sql_literal(v) for v in row) + ")" for row in rows)
    return spark.sql(f"SELECT * FROM VALUES {body} AS t({', '.join(columns)})")


@pytest.fixture
def table(spark):
    """table(rows, columns): a plain DataFrame."""
    return lambda rows, columns: values_frame(spark, rows, columns)


@pytest.fixture
def frame(spark):
    """frame(rows, columns): a raw-like DataFrame; _ingested_at and _source are added."""

    def make(rows, columns):
        data = [tuple(r) + (INGESTED, "test") for r in rows]
        return values_frame(spark, data, list(columns) + ["_ingested_at", "_source"])

    return make
