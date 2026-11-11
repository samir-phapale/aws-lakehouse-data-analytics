-- Repeat customers by region
SELECT region,
       count(*)                                                               AS customers,
       sum(CASE WHEN is_repeat_customer THEN 1 ELSE 0 END)                    AS repeat_customers,
       round(100.0 * avg(CASE WHEN is_repeat_customer THEN 1 ELSE 0 END), 2)  AS repeat_pct
FROM dim_customer
GROUP BY region
ORDER BY customers DESC;
