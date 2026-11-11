#!/usr/bin/env bash
# Copies the first N files of TPC-H customer (s3://dory-public/tpch/1000/customer/, scale 1000 is
# far more than dev needs) to files/tpch_customer/ in the source-files bucket for DataSync.
# That bucket denies listing to our account, so --generate builds the same table with DuckDB
# dbgen ('|'-delimited, no header) and uploads it instead.
#
# Usage: scripts/copy_tpch_source.sh [--files N] [--list] [--generate SF]
#   --files N       number of files to copy (default 3)
#   --list          only list the source and exit
#   --generate SF   generate at scale factor SF (1 = 150,000 rows); needs: pip install duckdb
set -euo pipefail
source "$(dirname "$0")/common.sh"

SOURCE="s3://dory-public/tpch/1000/customer/"
FILES=3
LIST_ONLY=false
GENERATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES="$2"; shift 2 ;;
    --list) LIST_ONLY=true; shift ;;
    --generate) GENERATE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if $LIST_ONLY; then
  aws s3 ls "$SOURCE" --human-readable --summarize | tail -n 20
  exit 0
fi

TARGET="s3://$(tf_out source_files_bucket_name)/files/tpch_customer/"

if [[ -n "$GENERATE" ]]; then
  OUT_DIR="$(mktemp -d)"
  trap 'rm -rf "$OUT_DIR"' EXIT
  echo "Generating TPC-H customer at scale factor ${GENERATE} with DuckDB"
  "$PYTHON" - "$GENERATE" "${OUT_DIR}/customer.tbl" <<'PY'
import sys
import duckdb

sf, out = float(sys.argv[1]), sys.argv[2]
con = duckdb.connect()
con.execute("INSTALL tpch; LOAD tpch")
con.execute(f"CALL dbgen(sf={sf})")
con.execute(f"COPY customer TO '{out}' (DELIMITER '|', HEADER false)")
print(f"  {con.execute('SELECT count(*) FROM customer').fetchone()[0]} rows")
PY
  aws s3 cp "${OUT_DIR}/customer.tbl" "${TARGET}customer.tbl" --only-show-errors
  echo "  customer.tbl -> ${TARGET}"
  exit 0
fi

mapfile -t keys < <(aws s3 ls "$SOURCE" | awk '$4 != "" {print $4}' | head -n "$FILES")
[[ ${#keys[@]} -gt 0 ]] || { echo "No files found under ${SOURCE}" >&2; exit 1; }

echo "Copying ${#keys[@]} file(s) from ${SOURCE} to ${TARGET}"
for key in "${keys[@]}"; do
  aws s3 cp "${SOURCE}${key}" "${TARGET}${key}" --only-show-errors
  echo "  ${key}"
done
echo "If these are not '|'-delimited .tbl files, set file_source_format in terraform.tfvars."
