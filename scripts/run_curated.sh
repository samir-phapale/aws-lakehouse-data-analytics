#!/usr/bin/env bash
# Builds the curated zone, runs the zone crawlers and checks the result in Athena.
# Run after scripts/run_transformed.sh.
# Usage: scripts/run_curated.sh [--tables fact_orders,agg_daily_sales] [--skip-job]   (default: all)
set -euo pipefail
export MSYS_NO_PATHCONV=1
source "$(dirname "$0")/common.sh"

TABLES="all"
SKIP_JOB=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tables) TABLES="$2"; shift 2 ;;
    --skip-job) SKIP_JOB=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

JOB="$(tf_out glue_transformed_to_curated_job_name)"
WORKGROUP="$(tf_out athena_workgroup)"
mapfile -t CRAWLERS < <(terraform -chdir="$TF_DIR" output -json glue_crawler_names \
  | "$PYTHON" -c 'import json, sys; print("\n".join(json.load(sys.stdin).values()))' | tr -d '\r')

if ! $SKIP_JOB; then
  run_glue_job "$JOB" "{\"--TABLES\":\"${TABLES}\"}"
fi

echo
echo "Crawling: ${CRAWLERS[*]}"
for crawler in "${CRAWLERS[@]}"; do
  aws glue start-crawler --name "$crawler" 2>/dev/null || echo "  ${crawler} already running"
done
for crawler in "${CRAWLERS[@]}"; do
  while [[ "$(aws glue get-crawler --name "$crawler" --query Crawler.State --output text)" != "READY" ]]; do
    sleep 15
  done
  last="$(aws glue get-crawler --name "$crawler" --query Crawler.LastCrawl.Status --output text)"
  echo "  ${crawler}: ${last}"
  if [[ "$last" != "SUCCEEDED" ]]; then
    aws glue get-crawler --name "$crawler" --query Crawler.LastCrawl.ErrorMessage --output text >&2
    exit 1
  fi
done

# athena <sql> <columns>: runs a query and prints the result as a table
athena() {
  local sql="$1" columns="$2" qid state
  qid="$(aws athena start-query-execution --work-group "$WORKGROUP" --query-string "$sql" --query QueryExecutionId --output text)"
  while true; do
    state="$(aws athena get-query-execution --query-execution-id "$qid" --query QueryExecution.Status.State --output text)"
    case "$state" in
      SUCCEEDED) break ;;
      FAILED|CANCELLED)
        aws athena get-query-execution --query-execution-id "$qid" --query QueryExecution.Status.StateChangeReason --output text >&2
        return 1 ;;
      *) sleep 2 ;;
    esac
  done
  aws athena get-query-results --query-execution-id "$qid" --query 'ResultSet.Rows[].Data[].VarCharValue' --output text \
    | awk -F'\t' -v n="$columns" '{for (i = 1; i <= NF; i++) {printf "%-22s", $i; if (i % n == 0) printf "\n"}}'
}

echo
echo "Athena (${WORKGROUP}): orders through the zones"
athena "$(cat "${ROOT}/sql/athena/09_zone_row_counts.sql")" 2
echo
echo "Athena: late delivery vs reviews"
athena "SELECT delivery_bucket, orders, avg_review_score FROM lakehouse_dev_curated.agg_review_vs_delivery ORDER BY bucket_order" 3
echo
echo "More saved queries: Athena console -> workgroup ${WORKGROUP} -> Saved queries (sql/athena/)"
