-- Row counts through the zones for orders: raw (latest day) -> transformed -> curated
SELECT 'raw'         AS zone, count(*) AS order_rows
FROM lakehouse_dev_raw.orders
WHERE ingest_date = (SELECT max(ingest_date) FROM lakehouse_dev_raw.orders)
UNION ALL
SELECT 'transformed', count(*) FROM lakehouse_dev_transformed.orders
UNION ALL
SELECT 'curated',     count(*) FROM lakehouse_dev_curated.fact_orders;
