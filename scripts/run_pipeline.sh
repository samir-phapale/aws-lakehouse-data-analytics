#!/usr/bin/env bash
# Starts the Step Functions pipeline (sources -> raw -> transformed -> DataBrew gate -> curated ->
# crawlers -> Redshift) and follows it. The MSK stream is not part of it; MySQL must be loaded.
# Usage: scripts/run_pipeline.sh [--skip-ingest]   (--skip-ingest: start at landing -> raw)
set -euo pipefail
export MSYS_NO_PATHCONV=1
source "$(dirname "$0")/common.sh"

INPUT='{}'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ingest) INPUT='{"skip_ingest": true}'; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

STATE_MACHINE="$(tf_out pipeline_state_machine_arn)"
execution="$(aws stepfunctions start-execution --state-machine-arn "$STATE_MACHINE" --input "$INPUT" --query executionArn --output text)"
echo "Started ${execution}"
echo "Console: https://us-east-1.console.aws.amazon.com/states/home?region=us-east-1#/v2/executions/details/${execution}"

last=""
while true; do
  status="$(aws stepfunctions describe-execution --execution-arn "$execution" --query status --output text)"
  step="$(aws stepfunctions get-execution-history --execution-arn "$execution" --reverse-order --max-results 20 \
    --query 'events[?stateEnteredEventDetails] | [0].stateEnteredEventDetails.name' --output text)"
  if [[ "$step" != "$last" ]]; then
    echo "  $(date -u +%H:%M:%S) ${step}"
    last="$step"
  fi
  case "$status" in
    RUNNING) sleep 20 ;;
    SUCCEEDED) echo "Pipeline SUCCEEDED"; exit 0 ;;
    *)
      echo "Pipeline ${status}" >&2
      aws stepfunctions describe-execution --execution-arn "$execution" --query '[error, cause]' --output text >&2
      exit 1 ;;
  esac
done
