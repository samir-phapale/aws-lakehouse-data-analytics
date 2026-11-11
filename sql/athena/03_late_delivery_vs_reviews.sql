-- Do late deliveries drive bad reviews?
SELECT delivery_bucket,
       orders,
       avg_review_score,
       round(100 * bad_review_ratio, 1)  AS bad_review_pct
FROM agg_review_vs_delivery
ORDER BY bucket_order;
