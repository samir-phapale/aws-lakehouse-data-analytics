#!/usr/bin/env bash
# Runs the stream end to end: starts the Glue streaming job (MSK -> landing), replays Olist orders
# with the EC2 producer over SSM, waits for batches in landing, stops the job and promotes the
# stream to raw.
#
# Usage: scripts/run_stream_ingestion.sh [--count N] [--offset N] [--rate R] [--keep-running] [--rebuild-deps]
#   --count N        orders to replay, about 4 events each (default 500; 0 = all 99,441)
#   --offset N       skip the first N orders by purchase time, to continue a previous replay
#   --rate R         events per second (default 50)
#   --keep-running   leave the streaming job running (billed until stopped; times out after 2 h)
#   --rebuild-deps   re-download the producer's Python packages
set -euo pipefail
source "$(dirname "$0")/common.sh"

COUNT=500
OFFSET=0
RATE=50
KEEP_RUNNING=false
REBUILD_DEPS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --offset) OFFSET="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=true; shift ;;
    --rebuild-deps) REBUILD_DEPS=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

REGION="${AWS_REGION:-us-east-1}"
ASSETS_BUCKET="$(tf_out glue_assets_bucket_name)"
SOURCE_BUCKET="$(tf_out source_files_bucket_name)"
LANDING_BUCKET="$(tf_out landing_bucket_name)"
RAW_BUCKET="$(tf_out raw_bucket_name)"
RAW_JOB="$(tf_out glue_landing_to_raw_job_name)"
STREAM_JOB="$(tf_out glue_stream_job_name)"
BOOTSTRAP="$(tf_out msk_bootstrap_brokers_iam)"
TOPIC="$(tf_out kafka_topic)"
INSTANCE_ID="$(tf_out producer_instance_id)"
DEPS_KEY="producer/deps.zip"

# The instance has no internet, so its pure-Python deps are downloaded here for its Python
# (AL2023: 3.9, arm64) and staged in S3
if $REBUILD_DEPS || ! aws s3api head-object --bucket "$ASSETS_BUCKET" --key "$DEPS_KEY" >/dev/null 2>&1; then
  build="$(mktemp -d)"
  trap 'rm -rf "$build"' EXIT
  echo "Staging producer dependencies in s3://${ASSETS_BUCKET}/${DEPS_KEY}"
  "$PYTHON" -m pip install --quiet --target "${build}/site" \
    --only-binary=:all: --implementation cp --python-version 3.9 \
    --platform manylinux2014_aarch64 \
    -r "${ROOT}/src/ingestion/kafka_streaming/requirements-producer.txt"
  "$PYTHON" -c 'import shutil, sys; shutil.make_archive(sys.argv[1], "zip", sys.argv[2])' \
    "${build}/deps" "${build}/site"
  aws s3 cp "${build}/deps.zip" "s3://${ASSETS_BUCKET}/${DEPS_KEY}" --only-show-errors
fi

RUN_ID="$(aws glue get-job-runs --job-name "$STREAM_JOB" \
  --query "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='WAITING'] | [0].Id" \
  --output text)"
if [[ "$RUN_ID" == "None" ]]; then
  RUN_ID="$(aws glue start-job-run --job-name "$STREAM_JOB" --query JobRunId --output text)"
  echo "Started Glue streaming job ${STREAM_JOB} (${RUN_ID})"
else
  echo "Glue streaming job ${STREAM_JOB} already running (${RUN_ID})"
fi

# The SSM agent needs a few minutes to register after the instance starts
echo "Waiting for producer instance ${INSTANCE_ID} to be online in SSM"
for _ in $(seq 1 30); do
  ping="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text)"
  [[ "$ping" == "Online" ]] && break
  sleep 20
done
[[ "$ping" == "Online" ]] || { echo "Producer instance is not online in SSM" >&2; exit 1; }

# Built with Python so quoting survives; MSYS_NO_PATHCONV stops Git Bash rewriting /opt paths
PARAMS="$(MSYS_NO_PATHCONV=1 "$PYTHON" -c 'import json, sys; print(json.dumps({"commands": sys.argv[1:], "executionTimeout": ["14400"]}))' \
  "set -euo pipefail" \
  "mkdir -p /opt/lakehouse-producer && cd /opt/lakehouse-producer" \
  "aws s3 cp s3://${ASSETS_BUCKET}/${DEPS_KEY} deps.zip --region ${REGION} --only-show-errors" \
  "aws s3 cp s3://${ASSETS_BUCKET}/producer/order_events_producer.py producer.py --region ${REGION} --only-show-errors" \
  "aws s3 cp s3://${SOURCE_BUCKET}/stream_replay/olist_orders_dataset.csv orders.csv --region ${REGION} --only-show-errors" \
  "rm -rf deps && python3 -m zipfile -e deps.zip deps" \
  "PYTHONPATH=deps python3 producer.py --bootstrap '${BOOTSTRAP}' --topic ${TOPIC} --region ${REGION} --orders-file orders.csv --count ${COUNT} --offset ${OFFSET} --rate ${RATE}")"

COMMAND_ID="$(MSYS_NO_PATHCONV=1 aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "lakehouse order events producer" \
  --parameters "$PARAMS" \
  --query Command.CommandId --output text)"
echo "Producer running (SSM command ${COMMAND_ID})"

while true; do
  status="$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending|InProgress|Delayed) sleep 10 ;;
    *) break ;;
  esac
done
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[[ "$status" == "Success" ]] || { echo "Producer failed: ${status}" >&2; exit 1; }

# First micro-batch needs job start-up plus one window; give it up to 15 minutes
echo "Waiting for JSON batches under s3://${LANDING_BUCKET}/stream/${TOPIC}/"
landed=false
for _ in $(seq 1 30); do
  state="$(aws glue get-job-run --job-name "$STREAM_JOB" --run-id "$RUN_ID" --query JobRun.JobRunState --output text)"
  case "$state" in
    FAILED|ERROR|TIMEOUT|STOPPED)
      echo "Streaming job ${state}" >&2
      aws glue get-job-run --job-name "$STREAM_JOB" --run-id "$RUN_ID" --query JobRun.ErrorMessage --output text >&2
      exit 1 ;;
  esac
  if aws s3 ls "s3://${LANDING_BUCKET}/stream/${TOPIC}/" --recursive 2>/dev/null | grep -q '\.json$'; then
    landed=true
    break
  fi
  echo "  streaming job ${state}, no batch landed yet"
  sleep 30
done

if $KEEP_RUNNING; then
  echo "Leaving ${STREAM_JOB} running (${RUN_ID}). Stop it with:"
  echo "  aws glue batch-stop-job-run --job-name ${STREAM_JOB} --job-run-ids ${RUN_ID}"
else
  # Let the last window finish so every sent event is committed
  $landed && sleep 90
  aws glue batch-stop-job-run --job-name "$STREAM_JOB" --job-run-ids "$RUN_ID" >/dev/null
  echo "Stopped ${STREAM_JOB} (${RUN_ID})"
fi

$landed || { echo "No batches under landing/stream/${TOPIC}/ after 15 minutes" >&2; exit 1; }

# Promote today's stream batches only; other sources in raw are untouched
run_glue_job "$RAW_JOB" '{"--SOURCES":"stream"}'

echo
echo "Raw stream contents:"
aws s3 ls "s3://${RAW_BUCKET}/stream/${TOPIC}/" --recursive --human-readable --summarize | tail -n 15
