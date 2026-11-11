-- Top 15 product categories by GMV, with share of total
SELECT category_en,
       round(sum(gmv), 2)                                AS gmv,
       sum(orders)                                       AS orders,
       round(100 * sum(gmv) / sum(sum(gmv)) OVER (), 2)  AS gmv_share_pct
FROM agg_daily_sales
GROUP BY category_en
ORDER BY gmv DESC
LIMIT 15;
