-- Top 20 sellers by GMV with review score and late / cancel rates
SELECT s.seller_id,
       d.state,
       round(sum(s.gmv), 2)                 AS gmv,
       sum(s.orders)                        AS orders,
       round(avg(s.avg_review_score), 2)    AS avg_review_score,
       round(100 * avg(s.late_ratio), 1)    AS late_pct,
       round(100 * avg(s.cancel_ratio), 1)  AS cancel_pct
FROM agg_seller_performance s
JOIN dim_seller d ON d.seller_id = s.seller_id
GROUP BY s.seller_id, d.state
ORDER BY gmv DESC
LIMIT 20;
