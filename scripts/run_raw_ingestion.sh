#!/usr/bin/env bash
# Loads landing (MySQL via Glue, files via DataSync), then promotes landing to raw.
# Upload the data first: scripts/upload_olist_data.sh and scripts/copy_tpch_source.sh
# Usage: scripts/run_raw_ingestion.sh [--load-mysql]   (--load-mysql: reload the Olist CSVs into MySQL first)
set -euo pipefail
source "$(dirname "$0")/common.sh"

INGEST_JOB="$(tf_out glue_ingest_job_name)"
RAW_JOB="$(tf_out glue_landing_to_raw_job_name)"
DATASYNC_TASK="$(tf_out datasync_task_arn)"
RAW_BUCKET="$(tf_out raw_bucket_name)"

run_datasync_task() {
  local exec_arn status
  exec_arn="$(aws datasync start-task-execution --task-arn "$DATASYNC_TASK" --query TaskExecutionArn --output text)"
  echo "Started DataSync execution ${exec_arn}"
  while true; do
    status="$(aws datasync describe-task-execution --task-execution-arn "$exec_arn" --query Status --output text)"
    case "$status" in
      SUCCESS) echo "  datasync: ${status}"; return 0 ;;
      ERROR)
        echo "  datasync: ${status}" >&2
        aws datasync describe-task-execution --task-execution-arn "$exec_arn" --query Result >&2
        return 1 ;;
      *) echo "  datasync: ${status}"; sleep 20 ;;
    esac
  done
}

if [[ "${1:-}" == "--load-mysql" ]]; then
  LOAD_MYSQL_JOB="$(tf_out glue_load_mysql_job_name)"
  run_glue_job "$LOAD_MYSQL_JOB"
fi

run_glue_job "$INGEST_JOB"
run_datasync_task
run_glue_job "$RAW_JOB"

echo
echo "Raw contents:"
aws s3 ls "s3://${RAW_BUCKET}/" --recursive --human-readable --summarize | tail -n 25
