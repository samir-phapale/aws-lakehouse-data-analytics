#!/usr/bin/env bash
# Uploads the Olist data set (Kaggle olistbr/brazilian-ecommerce) to the source-files bucket:
# mysql_load/ for the Glue MySQL loader, stream_replay/ for the EC2 producer.
# Usage: scripts/upload_olist_data.sh <archive.zip | folder with the 9 CSVs>
set -euo pipefail
source "$(dirname "$0")/common.sh"

SRC="${1:?usage: $0 <archive.zip | folder with the Olist CSVs>}"
BUCKET="$(tf_out source_files_bucket_name)"

if [[ -f "$SRC" ]]; then
  DATA_DIR="$(mktemp -d)"
  trap 'rm -rf "$DATA_DIR"' EXIT
  "$PYTHON" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$SRC" "$DATA_DIR"
else
  DATA_DIR="$SRC"
fi

upload() {
  local file="$1" key="$2"
  [[ -f "${DATA_DIR}/${file}" ]] || { echo "Missing ${file} in ${SRC}" >&2; exit 1; }
  aws s3 cp "${DATA_DIR}/${file}" "s3://${BUCKET}/${key}" --only-show-errors
  echo "  ${file} -> s3://${BUCKET}/${key}"
}

echo "MySQL source tables (loaded by the Glue loader job)"
upload olist_customers_dataset.csv           mysql_load/customers.csv
upload olist_orders_dataset.csv              mysql_load/orders.csv
upload olist_order_items_dataset.csv         mysql_load/order_items.csv
upload olist_order_payments_dataset.csv      mysql_load/order_payments.csv
upload olist_products_dataset.csv            mysql_load/products.csv
upload olist_sellers_dataset.csv             mysql_load/sellers.csv
upload olist_order_reviews_dataset.csv       mysql_load/order_reviews.csv
upload olist_geolocation_dataset.csv         mysql_load/geolocation.csv
upload product_category_name_translation.csv mysql_load/category_translation.csv

echo "Stream replay (read by the EC2 producer)"
upload olist_orders_dataset.csv stream_replay/olist_orders_dataset.csv
