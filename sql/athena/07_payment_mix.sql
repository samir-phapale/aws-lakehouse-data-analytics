-- Payment type mix and average installments
SELECT payment_type,
       count(*)                             AS orders,
       round(sum(payment_value), 2)         AS payment_value,
       round(avg(payment_installments), 1)  AS avg_installments
FROM fact_orders
WHERE payment_type IS NOT NULL
GROUP BY payment_type
ORDER BY orders DESC;
