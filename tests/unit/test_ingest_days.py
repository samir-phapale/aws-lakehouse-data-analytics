"""Unit tests for the landing_to_raw day selection (src/ingestion/landing_to_raw/ingest_days.py)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "ingestion" / "landing_to_raw"))

from ingest_days import folder_days, stream_days  # noqa: E402

LANDED = ["2026-11-08", "2026-11-09", "2026-11-11"]


def test_folder_days_reads_and_sorts_dates():
    folders = [
        "s3://landing/stream/orders/ingest_date=2026-11-11",
        "s3://landing/stream/orders/ingest_date=2026-11-08/",
        "s3://landing/stream/orders/_spark_metadata",
    ]
    assert folder_days(folders) == ["2026-11-08", "2026-11-11"]


def test_first_run_promotes_every_landed_day():
    assert stream_days(LANDED, None, "today") == LANDED


def test_redoes_latest_raw_day_and_catches_up_missed_days():
    assert stream_days(LANDED, "2026-11-09", "today") == ["2026-11-09", "2026-11-11"]


def test_nothing_new_still_redoes_latest_day():
    assert stream_days(LANDED, "2026-11-11", "today") == ["2026-11-11"]


def test_explicit_date_promotes_only_that_day():
    assert stream_days(LANDED, "2026-11-09", "2026-11-08") == ["2026-11-08"]
