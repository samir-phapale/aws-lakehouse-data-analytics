-- Average delivery time and late share by customer state
SELECT customer_state,
       sum(orders)                                              AS orders,
       round(sum(avg_delivery_days * orders) / sum(orders), 1)  AS avg_delivery_days,
       round(100 * sum(late_ratio * orders) / sum(orders), 1)   AS late_pct
FROM agg_delivery_performance
GROUP BY customer_state
ORDER BY avg_delivery_days DESC;
