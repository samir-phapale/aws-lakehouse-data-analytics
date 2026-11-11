-- Monthly GMV, orders and average ticket
SELECT date_trunc('month', purchase_date)  AS month,
       round(sum(gmv), 2)                  AS gmv,
       sum(orders)                         AS orders,
       round(sum(gmv) / sum(orders), 2)    AS avg_ticket
FROM agg_daily_sales
GROUP BY 1
ORDER BY 1;
