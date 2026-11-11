-- Top 20 sellers by GMV with review score and late / cancel rates (monthly rows weighted by orders)
SELECT s.seller_id,
       d.state,
       round(sum(s.gmv), 2)  AS gmv,
       sum(s.orders)         AS orders,
       round(sum(s.avg_review_score * s.orders) / sum(CASE WHEN s.avg_review_score IS NOT NULL THEN s.orders END), 2) AS avg_review_score,
       round(100 * sum(s.late_ratio * s.orders) / sum(CASE WHEN s.late_ratio IS NOT NULL THEN s.orders END), 1)       AS late_pct,
       round(100 * sum(s.cancel_ratio * s.orders) / sum(s.orders), 1)                                                 AS cancel_pct
FROM agg_seller_performance s
JOIN dim_seller d ON d.seller_id = s.seller_id
GROUP BY s.seller_id, d.state
ORDER BY gmv DESC
LIMIT 20;
