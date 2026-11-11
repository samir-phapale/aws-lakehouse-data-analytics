-- Example warehouse queries over the loaded marts (Redshift query editor v2, workgroup lakehouse-dev-warehouse)

-- Monthly GMV by region
SELECT date_trunc('month', f.purchase_date) AS month, g.region, sum(f.line_total) AS gmv
FROM marts.fact_order_items f
JOIN marts.dim_customer c ON c.customer_unique_id = f.customer_unique_id
JOIN marts.dim_geography g ON g.zip_code_prefix = c.zip_code_prefix
GROUP BY 1, 2
ORDER BY 1, 2;

-- Late deliveries vs review score
SELECT delivery_bucket, orders, avg_review_score, bad_review_ratio
FROM marts.agg_review_vs_delivery
ORDER BY bucket_order;

-- Spectrum (no load needed): query the lake directly
SELECT c_mktsegment, sum(customers) AS customers
FROM spectrum_curated.agg_tpch_customer_segment
GROUP BY 1;
