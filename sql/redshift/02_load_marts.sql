-- Full refresh of schema marts from Spectrum, run by the pipeline as one Data API batch (one transaction)
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.dim_date;
CREATE TABLE marts.dim_date AS SELECT * FROM spectrum_curated.dim_date;

DROP TABLE IF EXISTS marts.dim_geography;
CREATE TABLE marts.dim_geography AS SELECT * FROM spectrum_curated.dim_geography;

DROP TABLE IF EXISTS marts.dim_customer;
CREATE TABLE marts.dim_customer AS SELECT * FROM spectrum_curated.dim_customer;

DROP TABLE IF EXISTS marts.dim_seller;
CREATE TABLE marts.dim_seller AS SELECT * FROM spectrum_curated.dim_seller;

DROP TABLE IF EXISTS marts.dim_product;
CREATE TABLE marts.dim_product AS SELECT * FROM spectrum_curated.dim_product;

DROP TABLE IF EXISTS marts.fact_order_items;
CREATE TABLE marts.fact_order_items AS SELECT * FROM spectrum_curated.fact_order_items;

DROP TABLE IF EXISTS marts.fact_orders;
CREATE TABLE marts.fact_orders AS SELECT * FROM spectrum_curated.fact_orders;

DROP TABLE IF EXISTS marts.agg_daily_sales;
CREATE TABLE marts.agg_daily_sales AS SELECT * FROM spectrum_curated.agg_daily_sales;

DROP TABLE IF EXISTS marts.agg_seller_performance;
CREATE TABLE marts.agg_seller_performance AS SELECT * FROM spectrum_curated.agg_seller_performance;

DROP TABLE IF EXISTS marts.agg_delivery_performance;
CREATE TABLE marts.agg_delivery_performance AS SELECT * FROM spectrum_curated.agg_delivery_performance;

DROP TABLE IF EXISTS marts.agg_review_vs_delivery;
CREATE TABLE marts.agg_review_vs_delivery AS SELECT * FROM spectrum_curated.agg_review_vs_delivery;

DROP TABLE IF EXISTS marts.agg_tpch_customer_segment;
CREATE TABLE marts.agg_tpch_customer_segment AS SELECT * FROM spectrum_curated.agg_tpch_customer_segment;
