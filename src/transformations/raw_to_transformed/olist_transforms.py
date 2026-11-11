"""Raw -> transformed rules for the Olist tables and the order-event stream.

Plain DataFrame functions with no I/O, so tests/unit can run them on small in-memory frames.
"""

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F

# Portuguese accents -> plain letters, so "São Paulo" and "sao paulo" become one city
ACCENTED = "áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ"
PLAIN = "aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn"

ORDER_STATUSES = [
    "created", "approved", "invoiced", "processing", "shipped", "delivered", "canceled", "unavailable",
]

# The two categories missing from the translation file
MISSING_CATEGORY_TRANSLATIONS = {
    "pc_gamer": "pc_gamer",
    "portateis_cozinha_e_preparadores_de_alimentos": "portable_kitchen_and_food_processors",
}

# Brazil's bounding box; Olist geolocation has points far outside it
BRAZIL_LAT = (-33.76, 5.28)
BRAZIL_LNG = (-73.99, -34.79)

# Terminal events share the last step's timestamp, so they rank after it
EVENT_RANK = {
    "ORDER_PURCHASED": 1,
    "ORDER_APPROVED": 2,
    "ORDER_SHIPPED": 3,
    "ORDER_DELIVERED": 4,
    "ORDER_CANCELED": 5,
    "ORDER_UNAVAILABLE": 5,
}

META = ["_ingested_at", "_source"]


def literal_map(mapping):
    return F.create_map(*[F.lit(x) for pair in mapping.items() for x in pair])


def first_row(frame: DataFrame, window) -> DataFrame:
    return frame.withColumn("_rank", F.row_number().over(window)).filter("_rank = 1").drop("_rank")


def clean_city(column):
    return F.trim(F.translate(F.lower(column), ACCENTED, PLAIN))


def zip_prefix(column):
    return F.lpad(F.trim(column.cast("string")), 5, "0")


def blank_to_null(column):
    trimmed = F.trim(column)
    return F.when(trimmed == "", None).otherwise(trimmed)


def one_line(column):
    return blank_to_null(F.regexp_replace(column, r"[\r\n]+", " "))


def customers(raw: DataFrame) -> DataFrame:
    return raw.select(
        F.trim("customer_id").alias("customer_id"),
        F.trim("customer_unique_id").alias("customer_unique_id"),
        zip_prefix(F.col("customer_zip_code_prefix")).alias("zip_code_prefix"),
        clean_city(F.col("customer_city")).alias("city"),
        F.upper(F.trim("customer_state")).alias("state"),
        *META,
    ).dropDuplicates(["customer_id"])


def sellers(raw: DataFrame) -> DataFrame:
    return raw.select(
        F.trim("seller_id").alias("seller_id"),
        zip_prefix(F.col("seller_zip_code_prefix")).alias("zip_code_prefix"),
        clean_city(F.col("seller_city")).alias("city"),
        F.upper(F.trim("seller_state")).alias("state"),
        *META,
    ).dropDuplicates(["seller_id"])


def products(raw: DataFrame, category_translation: DataFrame) -> DataFrame:
    translation = category_translation.select(
        F.trim("product_category_name").alias("category_pt"),
        F.trim("product_category_name_english").alias("file_en"),
    )
    manual_en = literal_map(MISSING_CATEGORY_TRANSLATIONS)[F.col("category_pt")]
    length = F.col("product_length_cm").cast("int")
    height = F.col("product_height_cm").cast("int")
    width = F.col("product_width_cm").cast("int")
    return (
        raw.withColumn("category_pt", F.coalesce(blank_to_null(F.col("product_category_name")), F.lit("unknown")))
        .join(translation, "category_pt", "left")
        .select(
            F.trim("product_id").alias("product_id"),
            F.col("category_pt").alias("category"),
            F.coalesce("file_en", manual_en, "category_pt").alias("category_en"),
            # Olist spells these "lenght"
            F.col("product_name_lenght").cast("int").alias("name_length"),
            F.col("product_description_lenght").cast("int").alias("description_length"),
            F.col("product_photos_qty").cast("int").alias("photos_qty"),
            F.col("product_weight_g").cast("int").alias("weight_g"),
            length.alias("length_cm"),
            height.alias("height_cm"),
            width.alias("width_cm"),
            (length * height * width).alias("volume_cm3"),
            *META,
        )
        .dropDuplicates(["product_id"])
    )


def orders(raw: DataFrame) -> DataFrame:
    purchased = F.col("order_purchase_timestamp").cast("timestamp")
    approved = F.col("order_approved_at").cast("timestamp")
    delivered = F.col("order_delivered_customer_date").cast("timestamp")
    estimated = F.col("order_estimated_delivery_date").cast("timestamp")
    status = F.lower(F.trim("order_status"))
    approval_seconds = F.unix_timestamp(approved) - F.unix_timestamp(purchased)
    return raw.select(
        F.trim("order_id").alias("order_id"),
        F.trim("customer_id").alias("customer_id"),
        status.alias("order_status"),
        purchased.alias("purchased_at"),
        approved.alias("approved_at"),
        F.col("order_delivered_carrier_date").cast("timestamp").alias("shipped_at"),
        delivered.alias("delivered_at"),
        estimated.alias("estimated_delivery_at"),
        F.to_date(purchased).alias("purchase_date"),
        F.datediff(delivered, purchased).alias("delivery_days"),
        # Dates, not timestamps: same rule as days_late, so a delivery on the due day is on time
        F.when(delivered.isNotNull(), F.datediff(delivered, estimated) > 0).alias("is_late"),
        F.round(approval_seconds / 3600, 2).alias("approval_hours"),
        # Some "delivered" orders have no delivery date; kept, but flagged
        ((status == "delivered") & delivered.isNull()).alias("dq_missing_delivery"),
        *META,
    ).dropDuplicates(["order_id"])


def order_items(raw: DataFrame) -> DataFrame:
    price = F.col("price").cast("decimal(10,2)")
    freight = F.col("freight_value").cast("decimal(10,2)")
    return raw.select(
        F.trim("order_id").alias("order_id"),
        F.col("order_item_id").cast("int").alias("order_item_id"),
        F.trim("product_id").alias("product_id"),
        F.trim("seller_id").alias("seller_id"),
        F.col("shipping_limit_date").cast("timestamp").alias("shipping_limit_at"),
        price.alias("price"),
        freight.alias("freight_value"),
        (price + freight).cast("decimal(11,2)").alias("line_total"),
        *META,
    ).dropDuplicates(["order_id", "order_item_id"])


def order_payments(raw: DataFrame) -> DataFrame:
    payment_type = F.lower(F.trim("payment_type"))
    return raw.select(
        F.trim("order_id").alias("order_id"),
        F.col("payment_sequential").cast("int").alias("payment_sequential"),
        F.when(payment_type == "not_defined", "unknown").otherwise(payment_type).alias("payment_type"),
        F.col("payment_installments").cast("int").alias("payment_installments"),
        F.col("payment_value").cast("decimal(10,2)").alias("payment_value"),
        *META,
    ).dropDuplicates(["order_id", "payment_sequential"])


def order_reviews(raw: DataFrame) -> DataFrame:
    reviews = raw.select(
        F.trim("review_id").alias("review_id"),
        F.trim("order_id").alias("order_id"),
        F.col("review_score").cast("int").alias("review_score"),
        one_line(F.col("review_comment_title")).alias("comment_title"),
        one_line(F.col("review_comment_message")).alias("comment_message"),
        F.col("review_creation_date").cast("timestamp").alias("created_at"),
        F.col("review_answer_timestamp").cast("timestamp").alias("answered_at"),
        *META,
    ).withColumn("has_comment", F.col("comment_title").isNotNull() | F.col("comment_message").isNotNull())
    # review_id alone is not unique; keep the latest answer per (review_id, order_id)
    latest = Window.partitionBy("review_id", "order_id").orderBy(F.col("answered_at").desc_nulls_last())
    return first_row(reviews, latest)


def geolocation(raw: DataFrame) -> DataFrame:
    """One row per zip prefix: median point inside Brazil, most common city/state."""
    points = raw.select(
        zip_prefix(F.col("geolocation_zip_code_prefix")).alias("zip_code_prefix"),
        F.col("geolocation_lat").cast("double").alias("lat"),
        F.col("geolocation_lng").cast("double").alias("lng"),
        clean_city(F.col("geolocation_city")).alias("city"),
        F.upper(F.trim("geolocation_state")).alias("state"),
        *META,
    ).filter(F.col("lat").between(*BRAZIL_LAT) & F.col("lng").between(*BRAZIL_LNG))
    centre = points.groupBy("zip_code_prefix").agg(
        F.percentile_approx("lat", 0.5).alias("lat"),
        F.percentile_approx("lng", 0.5).alias("lng"),
        F.count(F.lit(1)).alias("points"),
        F.max("_ingested_at").alias("_ingested_at"),
        F.first("_source").alias("_source"),
    )
    most_common = Window.partitionBy("zip_code_prefix").orderBy(F.desc("n"), "city", "state")
    place = first_row(
        points.groupBy("zip_code_prefix", "city", "state").agg(F.count(F.lit(1)).alias("n")), most_common
    ).drop("n")
    return centre.join(place, "zip_code_prefix").select(
        "zip_code_prefix", "city", "state", "lat", "lng", "points", *META
    )


def order_events(raw: DataFrame) -> DataFrame:
    """Replays and Glue retries repeat events; event_id is deterministic, so keep the first copy."""
    events = raw.select(
        F.trim("event_id").alias("event_id"),
        F.upper(F.trim("event_type")).alias("event_type"),
        F.to_timestamp("event_time", "yyyy-MM-dd HH:mm:ss").alias("event_time"),
        F.trim("order_id").alias("order_id"),
        F.trim("customer_id").alias("customer_id"),
        F.lower(F.trim("final_order_status")).alias("final_order_status"),
        F.to_timestamp("estimated_delivery_date", "yyyy-MM-dd HH:mm:ss").alias("estimated_delivery_at"),
        F.to_timestamp("produced_at").alias("produced_at"),
        *META,
    ).withColumn("event_rank", literal_map(EVENT_RANK)[F.col("event_type")])
    return first_row(events, Window.partitionBy("event_id").orderBy("_ingested_at"))


def order_status_current(events: DataFrame) -> DataFrame:
    """What the stream says each order is now: its latest lifecycle step."""
    latest = Window.partitionBy("order_id").orderBy(
        F.desc("event_time"), F.desc("event_rank"), F.desc("_ingested_at")
    )
    return first_row(events, latest).select(
        "order_id",
        "customer_id",
        F.col("event_type").alias("last_event_type"),
        F.col("event_time").alias("last_event_at"),
        "final_order_status",
        *META,
    )
