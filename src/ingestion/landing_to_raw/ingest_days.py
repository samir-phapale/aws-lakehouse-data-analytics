"""Which landing days a landing_to_raw run promotes. No Spark here, so it is unit-tested locally."""

import re

DAY_FOLDER = re.compile(r"ingest_date=(\d{4}-\d{2}-\d{2})/?$")


def folder_days(folders):
    """Sorted ingest dates from landing folder names (".../ingest_date=YYYY-MM-DD/")."""
    return sorted({m.group(1) for f in folders if (m := DAY_FOLDER.search(f))})


def stream_days(landing_days, latest_raw_day, requested):
    """The streaming job appends to today's folder all day, so a "today" run redoes the newest day
    already in raw (it may have been cut off) and every later landing day, including days with no run.
    An explicit date promotes only that day."""
    if requested != "today":
        return [requested]
    return [d for d in landing_days if latest_raw_day is None or d >= latest_raw_day]
