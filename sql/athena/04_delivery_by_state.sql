-- Average delivery time and late share by customer state (fact_orders: one row per order)
SELECT customer_state,
       count(*)                                                    AS orders,
       round(avg(delivery_days), 1)                                AS avg_delivery_days,
       round(100 * avg(CASE WHEN is_late THEN 1.0 ELSE 0.0 END), 1) AS late_pct
FROM fact_orders
WHERE delivery_days IS NOT NULL
GROUP BY customer_state
ORDER BY avg_delivery_days DESC;
