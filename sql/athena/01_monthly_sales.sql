-- Monthly GMV, orders and average ticket (fact_orders: one row per order)
SELECT date_trunc('month', purchase_date)        AS month,
       round(sum(order_total), 2)                AS gmv,
       count(*)                                  AS orders,
       round(sum(order_total) / count(*), 2)     AS avg_ticket
FROM fact_orders
WHERE order_total IS NOT NULL
GROUP BY 1
ORDER BY 1;
