#!/usr/bin/env bash
# Builds the transformed zone from raw (tables, _dq/ Parquet copies, _quarantine/ rejected rows).
# Run after raw is loaded.
# Usage: scripts/run_transformed.sh [--tables customers,orders]   (default: all)
set -euo pipefail
source "$(dirname "$0")/common.sh"

TABLES="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tables) TABLES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

JOB="$(tf_out glue_raw_to_transformed_job_name)"
BUCKET="$(tf_out transformed_bucket_name)"

run_glue_job "$JOB" "{\"--TABLES\":\"${TABLES}\"}"

echo
echo "Transformed tables:"
aws s3 ls "s3://${BUCKET}/" | grep -v ' _' || true
echo
echo "Quarantine (the job log prints row counts per table):"
aws s3 ls "s3://${BUCKET}/_quarantine/" --recursive --human-readable --summarize | tail -n 3
