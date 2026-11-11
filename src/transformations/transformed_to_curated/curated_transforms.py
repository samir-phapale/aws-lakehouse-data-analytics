"""Transformed -> curated rules: a star schema at order-item grain plus business aggregates.

Plain DataFrame functions with no I/O, so tests/unit can run them on small in-memory frames.
"""

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F

# Brazil's five official regions, by state
REGIONS = {
    "N": ["AC", "AP", "AM", "PA", "RO", "RR", "TO"],
    "NE": ["AL", "BA", "CE", "MA", "PB", "PE", "PI", "RN", "SE"],
    "CO": ["DF", "GO", "MT", "MS"],
    "SE": ["ES", "MG", "RJ", "SP"],
    "S": ["PR", "RS", "SC"],
}
STATE_REGION = {state: code for code, states in REGIONS.items() for state in states}

# TPC-H nation table (n_nationkey 0-24), fixed by the spec
TPCH_NATIONS = [
    "ALGERIA", "ARGENTINA", "BRAZIL", "CANADA", "EGYPT", "ETHIOPIA", "FRANCE", "GERMANY",
    "INDIA", "INDONESIA", "IRAN", "IRAQ", "JAPAN", "JORDAN", "KENYA", "MOROCCO", "MOZAMBIQUE",
    "PERU", "CHINA", "ROMANIA", "SAUDI ARABIA", "VIETNAM", "RUSSIA", "UNITED KINGDOM",
    "UNITED STATES",
]


def literal_map(mapping):
    return F.create_map(*[F.lit(x) for pair in mapping.items() for x in pair])


def region(state):
    return F.coalesce(literal_map(STATE_REGION)[state], F.lit("unknown"))


def date_key(column):
    return F.date_format(column, "yyyyMMdd").cast("int")


def ratio(condition):
    """Share of rows where condition is true, ignoring rows where it is null."""
    return F.round(F.avg(F.when(condition.isNotNull(), condition.cast("int"))), 4)


def dim_date(orders: DataFrame) -> DataFrame:
    """One row per day from the first to the last purchase day."""
    days = orders.agg(F.min("purchase_date").alias("first"), F.max("purchase_date").alias("last")).select(
        F.explode(F.sequence("first", "last")).alias("date")
    )
    return days.select(
        date_key(F.col("date")).alias("date_key"),
        "date",
        F.year("date").alias("year"),
        F.quarter("date").alias("quarter"),
        F.month("date").alias("month"),
        F.date_format("date", "MMMM").alias("month_name"),
        F.dayofmonth("date").alias("day"),
        F.dayofweek("date").alias("day_of_week"),
        F.dayofweek("date").isin(1, 7).alias("is_weekend"),
    )


def dim_geography(geolocation: DataFrame) -> DataFrame:
    return geolocation.select(
        "zip_code_prefix", "city", "state", region(F.col("state")).alias("region"), "lat", "lng"
    )


def dim_customer(customers: DataFrame, orders: DataFrame) -> DataFrame:
    """One row per person (customer_unique_id); Olist issues a new customer_id per order."""
    order_dates = orders.select("order_id", "customer_id", "purchased_at", "purchase_date")
    placed = customers.join(order_dates, "customer_id", "left")
    latest = Window.partitionBy("customer_unique_id").orderBy(F.desc_nulls_last("purchased_at"))
    address = (
        placed.withColumn("_rank", F.row_number().over(latest))
        .filter("_rank = 1")
        .select("customer_unique_id", "zip_code_prefix", "city", "state")
    )
    history = placed.groupBy("customer_unique_id").agg(
        F.min("purchase_date").alias("first_order_date"),
        F.max("purchase_date").alias("last_order_date"),
        F.countDistinct("order_id").alias("order_count"),
    )
    return address.join(history, "customer_unique_id").select(
        "customer_unique_id",
        "zip_code_prefix",
        "city",
        "state",
        region(F.col("state")).alias("region"),
        "first_order_date",
        "last_order_date",
        "order_count",
        (F.col("order_count") > 1).alias("is_repeat_customer"),
    )


def dim_seller(sellers: DataFrame, geolocation: DataFrame) -> DataFrame:
    points = geolocation.select("zip_code_prefix", "lat", "lng")
    return sellers.join(points, "zip_code_prefix", "left").select(
        "seller_id", "zip_code_prefix", "city", "state", region(F.col("state")).alias("region"), "lat", "lng"
    )


def dim_product(products: DataFrame) -> DataFrame:
    weight, volume = F.col("weight_g"), F.col("volume_cm3")
    return products.select(
        "product_id",
        "category",
        "category_en",
        "photos_qty",
        "weight_g",
        "volume_cm3",
        F.when(weight.isNull(), "unknown")
        .when(weight < 500, "light (<0.5 kg)")
        .when(weight < 5000, "medium (0.5-5 kg)")
        .otherwise("heavy (5 kg+)")
        .alias("weight_band"),
        F.when(volume.isNull(), "unknown")
        .when(volume < 1000, "small (<1 L)")
        .when(volume < 20000, "medium (1-20 L)")
        .otherwise("large (20 L+)")
        .alias("size_band"),
    )


def _order_context(orders: DataFrame, customers: DataFrame) -> DataFrame:
    people = customers.select("customer_id", "customer_unique_id", F.col("state").alias("customer_state"))
    return orders.join(people, "customer_id", "left").select(
        "order_id",
        "customer_unique_id",
        "customer_state",
        date_key(F.col("purchase_date")).alias("date_key"),
        "purchase_date",
        "order_status",
        "delivery_days",
        "is_late",
        F.datediff("delivered_at", "estimated_delivery_at").alias("days_late"),
        "approval_hours",
    )


def fact_order_items(order_items: DataFrame, orders: DataFrame, customers: DataFrame) -> DataFrame:
    context = _order_context(orders, customers)
    return order_items.join(context, "order_id").select(
        "order_id",
        "order_item_id",
        "product_id",
        "seller_id",
        "customer_unique_id",
        "customer_state",
        "date_key",
        "purchase_date",
        "order_status",
        "price",
        "freight_value",
        "line_total",
        "delivery_days",
        "is_late",
    )


def fact_orders(
    orders: DataFrame,
    customers: DataFrame,
    order_items: DataFrame,
    order_payments: DataFrame,
    order_reviews: DataFrame,
) -> DataFrame:
    items = order_items.groupBy("order_id").agg(
        F.count(F.lit(1)).alias("items_count"),
        F.countDistinct("seller_id").alias("sellers_count"),
        F.sum("price").alias("items_value"),
        F.sum("freight_value").alias("freight_value"),
        F.sum("line_total").alias("order_total"),
    )
    first_payment = Window.partitionBy("order_id").orderBy("payment_sequential")
    payments = (
        order_payments.withColumn("_rank", F.row_number().over(first_payment))
        .groupBy("order_id")
        .agg(
            F.sum("payment_value").alias("payment_value"),
            F.max("payment_installments").alias("payment_installments"),
            F.max(F.when(F.col("_rank") == 1, F.col("payment_type"))).alias("payment_type"),
        )
    )
    reviews = order_reviews.groupBy("order_id").agg(F.round(F.avg("review_score"), 2).alias("review_score"))
    return (
        _order_context(orders, customers)
        .join(items, "order_id", "left")
        .join(payments, "order_id", "left")
        .join(reviews, "order_id", "left")
        .select(
            "order_id",
            "customer_unique_id",
            "customer_state",
            "date_key",
            "purchase_date",
            "order_status",
            F.coalesce("items_count", F.lit(0)).alias("items_count"),
            "sellers_count",
            "items_value",
            "freight_value",
            "order_total",
            "payment_value",
            "payment_installments",
            "payment_type",
            "review_score",
            "delivery_days",
            "days_late",
            "is_late",
            "approval_hours",
        )
    )


def agg_daily_sales(fact_items: DataFrame, products: DataFrame) -> DataFrame:
    categories = products.select("product_id", "category_en")
    return (
        fact_items.join(categories, "product_id", "left")
        .groupBy("purchase_date", "customer_state", F.coalesce("category_en", F.lit("unknown")).alias("category_en"))
        .agg(
            F.sum("line_total").alias("gmv"),
            F.countDistinct("order_id").alias("orders"),
            F.count(F.lit(1)).alias("items"),
        )
        .withColumn("avg_ticket", F.round(F.col("gmv") / F.col("orders"), 2))
    )


def agg_seller_performance(fact_items: DataFrame, fact_ord: DataFrame) -> DataFrame:
    per_order = fact_ord.select("order_id", "review_score")
    seller_orders = (
        fact_items.groupBy("seller_id", "order_id", "purchase_date", "order_status", "is_late")
        .agg(F.sum("line_total").alias("seller_total"))
        .join(per_order, "order_id", "left")
    )
    return seller_orders.groupBy("seller_id", F.trunc("purchase_date", "month").alias("month")).agg(
        F.sum("seller_total").alias("gmv"),
        F.countDistinct("order_id").alias("orders"),
        F.round(F.avg("review_score"), 2).alias("avg_review_score"),
        ratio(F.col("is_late")).alias("late_ratio"),
        ratio(F.col("order_status") == "canceled").alias("cancel_ratio"),
    )


def agg_delivery_performance(fact_items: DataFrame, sellers: DataFrame) -> DataFrame:
    seller_state = sellers.select("seller_id", F.col("state").alias("seller_state"))
    shipments = (
        fact_items.filter(F.col("delivery_days").isNotNull())
        .select("order_id", "seller_id", "customer_state", "purchase_date", "delivery_days", "is_late")
        .distinct()
        .join(seller_state, "seller_id", "left")
    )
    return shipments.groupBy(
        "customer_state", "seller_state", F.trunc("purchase_date", "month").alias("month")
    ).agg(
        F.countDistinct("order_id").alias("orders"),
        F.round(F.avg("delivery_days"), 2).alias("avg_delivery_days"),
        F.percentile_approx("delivery_days", 0.5).alias("median_delivery_days"),
        ratio(F.col("is_late")).alias("late_ratio"),
    )


def agg_review_vs_delivery(fact_ord: DataFrame) -> DataFrame:
    """Shows whether late deliveries drive bad reviews."""
    days_late = F.col("days_late")
    bucket = (
        F.when(F.col("delivery_days").isNull(), "5 not delivered")
        .when(days_late <= 0, "1 on time")
        .when(days_late <= 3, "2 1-3 days late")
        .when(days_late <= 7, "3 4-7 days late")
        .otherwise("4 8+ days late")
    )
    return (
        fact_ord.filter(F.col("review_score").isNotNull())
        .withColumn("_bucket", bucket)
        .groupBy("_bucket")
        .agg(
            F.count(F.lit(1)).alias("orders"),
            F.round(F.avg("review_score"), 2).alias("avg_review_score"),
            ratio(F.col("review_score") <= 2).alias("bad_review_ratio"),
        )
        .select(
            F.substring("_bucket", 1, 1).cast("int").alias("bucket_order"),
            F.expr("substring(_bucket, 3)").alias("delivery_bucket"),
            "orders",
            "avg_review_score",
            "bad_review_ratio",
        )
    )


def agg_tpch_customer_segment(tpch_customer: DataFrame) -> DataFrame:
    nations = literal_map(dict(enumerate(TPCH_NATIONS)))
    return tpch_customer.groupBy(
        "c_mktsegment", "c_nationkey", nations[F.col("c_nationkey")].alias("nation")
    ).agg(
        F.count(F.lit(1)).alias("customers"),
        F.sum("c_acctbal").alias("total_acctbal"),
        F.round(F.avg("c_acctbal"), 2).alias("avg_acctbal"),
        ratio(F.col("c_acctbal") < 0).alias("negative_balance_ratio"),
    )
