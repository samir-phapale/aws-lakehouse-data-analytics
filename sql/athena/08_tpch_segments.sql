-- TPC-H customers: account balance by market segment
SELECT c_mktsegment,
       sum(customers)                                 AS customers,
       round(sum(total_acctbal), 2)                   AS total_acctbal,
       round(sum(total_acctbal) / sum(customers), 2)  AS avg_acctbal
FROM agg_tpch_customer_segment
GROUP BY c_mktsegment
ORDER BY total_acctbal DESC;
