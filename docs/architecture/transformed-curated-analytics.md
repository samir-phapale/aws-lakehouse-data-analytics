# Transformed, curated and analytics: services and connections

This page covers everything after raw: the transformed zone, the DataBrew quality gate, the
curated zone, the catalog and the consumers (Athena, Redshift). Sources, landing and raw are in
[landing-raw-layer.md](landing-raw-layer.md). Everything here is created by
`infrastructure/terraform`. Dev names are shown; `<acct>` is the account ID.

## Data flow

```
raw/rds/salesdb/*          ┐
raw/files/tpch_customer    ├─ Glue raw -> transformed ─> transformed/<table>/              Delta
raw/stream/order_events    ┘                         ├─> transformed/_dq/<table>/          Parquet copy for DataBrew
                                                     └─> transformed/_quarantine/<table>/  rejected rows, with _dq_reason
transformed/_dq/* ─ DataBrew profile job + ruleset per table ─> transformed/_dq_reports/ ─ dq_gate Lambda
  └─ every table passed ─> Glue transformed -> curated ─> curated/dim_*, fact_*, agg_*     Delta
       └─> 4 crawlers ─> Glue catalog ─> Athena (workgroup lakehouse-dev-analytics)
                                      └─> Redshift Serverless: Spectrum schema + marts load
```

Step Functions `lakehouse-dev-pipeline` runs the whole chain: IngestSources (MySQL, DataSync) ->
LandingToRaw -> RawToTransformed -> DataQuality (one branch per table: ProfileJob, Gate) ->
TransformedToCurated -> Crawl -> CreateExternalSchema -> LoadMarts. Any failure, including a failed
quality gate, stops the run and sends an SNS alert.

## Design choices

1. **Delta in raw, transformed and curated** on Glue 4.0 (Delta 2.1). Delta 2.1 has no
   `WHEN NOT MATCHED BY SOURCE`, so batch tables are rebuilt from the latest raw snapshot instead
   of merged. Every run is idempotent.
2. **Rules as plain functions** (`DataFrame -> DataFrame`) in
   `src/transformations/raw_to_transformed/` and `transformed_to_curated/`, shipped with
   `--extra-py-files`. Thin Glue entry scripts call them, so they are unit-tested locally.
3. **One Glue job per zone**, looping over its tables in dependency order (`--TABLES` runs a subset).
4. **Row rules in Glue, table rules in DataBrew.** Rows that cannot be fixed (null keys, broken
   references) go to `_quarantine/`. Table-level checks (row counts, completeness, uniqueness,
   allowed values, ranges) are DataBrew rulesets in `modules/databrew/rules.tf`.
5. **DataBrew reads a Parquet copy.** DataBrew cannot read Delta, and reading a Delta folder as plain
   Parquet would pick up files the Delta log has removed, so the transformed job also writes
   `_dq/<table>/`.
6. **The gate fails closed.** A DataBrew profile job succeeds even when rules fail. The `dq_gate`
   Lambda reads the validation report named in the job's outputs and passes a table only if the
   report has at least one rule result and every status is `SUCCEEDED`.

## Transformed tables

| Table | Key | Source (raw) | Rules |
| --- | --- | --- | --- |
| `customers` | `customer_id` | rds customers | trim, city lower-case without accents, state upper, zip as 5-char string |
| `sellers` | `seller_id` | rds sellers | same as customers |
| `products` | `product_id` | rds products + category_translation | fix misspelt column names, `category_en`, null -> `unknown`, `volume_cm3` |
| `orders` | `order_id` | rds orders | status check, `delivery_days`, `is_late` (delivered after the estimated date, compared as dates), `approval_hours`, `dq_missing_delivery` |
| `order_items` | `(order_id, order_item_id)` | rds order_items | `line_total = price + freight_value` |
| `order_payments` | `(order_id, payment_sequential)` | rds order_payments | `not_defined` -> `unknown` |
| `order_reviews` | `(review_id, order_id)` | rds order_reviews | score 1-5, collapse line breaks, latest answer per key, `has_comment` |
| `geolocation` | `zip_code_prefix` | rds geolocation | drop points outside Brazil, one row per zip |
| `order_events` | `event_id` | stream order_events | parse `event_time`; rebuilt from every raw day, duplicates removed by `event_id` |
| `order_status_current` | `order_id` | transformed order_events | latest event per order (no DataBrew ruleset) |
| `tpch_customer` | `c_custkey` | files tpch_customer | cast keys to int, `c_acctbal` to decimal(15,2), trim, segment upper |

Batch tables read the newest `ingest_date` of each raw table; `order_events` reads every day. Every
row keeps `_ingested_at` and `_source` and adds `_processed_at`.

## Curated tables

Star schema plus aggregates, rebuilt in full each run. The grain matters when querying: summing an
aggregate across a dimension it was not built on can count an order more than once.

| Table | Grain | Notes |
| --- | --- | --- |
| `dim_customer` | customer_unique_id | latest city/state, first/last order date, order count |
| `dim_seller` | seller_id | city/state, lat/lng from geolocation |
| `dim_product` | product_id | English category, size/weight bands |
| `dim_date` | day | calendar attributes |
| `dim_geography` | zip_code_prefix | state, region, lat/lng |
| `fact_order_items` | order item | price, freight, line_total, keys to all dims, delivery metrics |
| `fact_orders` | order | totals, payments, review score, `delivery_days`, `days_late`, `is_late`. Use for order counts and per-order delivery |
| `agg_daily_sales` | day x customer state x category | GMV, orders, items. An order with two categories is in two rows |
| `agg_seller_performance` | seller x month | GMV, orders, average review, late and cancel ratios. Weight by `orders` when rolling up |
| `agg_delivery_performance` | customer state x seller state x month | seller lanes: a multi-seller order counts once per seller |
| `agg_review_vs_delivery` | lateness bucket | average review score by lateness (buckets from `days_late`) |
| `agg_payment_mix` | payment type | payment level: a split payment counts in each type |
| `agg_tpch_customer_segment` | market segment x nation | customers, total/average account balance |

## Catalog and access

- Glue databases `lakehouse_dev_raw`, `_transformed`, `_curated`, one crawler per zone (native
  Delta tables for Athena v3), and a fourth crawler that writes symlink manifests for Redshift
  Spectrum (`lakehouse_dev_spectrum`).
- Lake Formation grants: crawlers get create/alter on their database; the admin principals get
  `SELECT` on every zone; Redshift gets `SELECT` on the Spectrum database.
- Athena workgroup `lakehouse-dev-analytics` with results in the glue-assets bucket (SSE-KMS), and
  the saved queries from `sql/athena/` against the curated database.

## Redshift

Redshift Serverless (namespace `lakehouse-dev-warehouse`, database `lakehouse`) in the VPC, not
publicly accessible. The pipeline creates the external schema `spectrum_curated`
(`sql/redshift/01_external_schema.sql`) and reloads the `marts` schema from it in one Data API
transaction (`sql/redshift/02_load_marts.sql`). Analyst examples are in
`sql/redshift/03_analyst_queries.sql`.
