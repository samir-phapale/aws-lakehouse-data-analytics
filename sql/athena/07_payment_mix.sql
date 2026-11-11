-- Payment type mix and average installments (payment level: split payments count in each type)
SELECT payment_type,
       orders,
       payments,
       round(payment_value, 2)  AS payment_value,
       avg_installments
FROM agg_payment_mix
ORDER BY payment_value DESC;
