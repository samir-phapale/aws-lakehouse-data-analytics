"""Unit tests for the raw -> transformed rules (src/transformations/raw_to_transformed)."""

from datetime import datetime
from decimal import Decimal

from pyspark.sql import functions as F

import olist_transforms as olist
import quality
import tpch_transforms as tpch


def rows(frame, *columns):
    return [tuple(r[c] for c in columns) for r in frame.orderBy(*columns).collect()]


def test_customers_cleans_city_state_and_zip(frame):
    raw = frame(
        [("c1", "u1", "1037", "  São Paulo ", "sp"), ("c1", "u1", "1037", "sao paulo", "SP")],
        ["customer_id", "customer_unique_id", "customer_zip_code_prefix", "customer_city", "customer_state"],
    )
    out = olist.customers(raw)
    assert rows(out, "customer_id", "zip_code_prefix", "city", "state") == [("c1", "01037", "sao paulo", "SP")]


def test_products_translates_category_and_fills_gaps(frame, table):
    raw = frame(
        [
            ("p1", "beleza_saude", 10, 20, 1, 500, 10, 2, 5),
            ("p2", None, None, None, None, 100, 1, 1, 1),
            ("p3", "pc_gamer", 5, 5, 1, 900, 30, 10, 20),
        ],
        [
            "product_id", "product_category_name", "product_name_lenght", "product_description_lenght",
            "product_photos_qty", "product_weight_g", "product_length_cm", "product_height_cm",
            "product_width_cm",
        ],
    )
    translation = table(
        [("beleza_saude", "health_beauty")], ["product_category_name", "product_category_name_english"]
    )
    out = olist.products(raw, translation)
    assert rows(out, "product_id", "category", "category_en", "volume_cm3") == [
        ("p1", "beleza_saude", "health_beauty", 100),
        ("p2", "unknown", "unknown", 1),
        ("p3", "pc_gamer", "pc_gamer", 6000),
    ]
    assert "name_length" in out.columns and "product_name_lenght" not in out.columns


def test_orders_delivery_metrics(frame):
    ts = datetime
    raw = frame(
        [
            ("o1", "c1", "delivered", ts(2018, 1, 1, 10), ts(2018, 1, 1, 12), ts(2018, 1, 2), ts(2018, 1, 11, 10), ts(2018, 1, 10)),
            ("o2", "c1", "Delivered", ts(2018, 1, 1, 10), None, None, None, ts(2018, 1, 10)),
            ("o3", "c2", "shipped", ts(2018, 1, 1, 10), ts(2018, 1, 1, 11), ts(2018, 1, 3), None, ts(2018, 1, 10)),
        ],
        [
            "order_id", "customer_id", "order_status", "order_purchase_timestamp", "order_approved_at",
            "order_delivered_carrier_date", "order_delivered_customer_date", "order_estimated_delivery_date",
        ],
    )
    out = olist.orders(raw)
    assert rows(out, "order_id", "order_status", "delivery_days", "is_late", "approval_hours", "dq_missing_delivery") == [
        ("o1", "delivered", 10, True, 2.0, False),
        ("o2", "delivered", None, None, None, True),
        ("o3", "shipped", None, None, 1.0, False),
    ]


def test_order_items_line_total(frame):
    raw = frame(
        [("o1", 1, "p1", "s1", datetime(2018, 1, 5), Decimal("10.50"), Decimal("2.25"))],
        ["order_id", "order_item_id", "product_id", "seller_id", "shipping_limit_date", "price", "freight_value"],
    )
    assert rows(olist.order_items(raw), "order_id", "line_total") == [("o1", Decimal("12.75"))]


def test_order_payments_not_defined_becomes_unknown(frame):
    raw = frame(
        [("o1", 1, "credit_card", 3, Decimal("50.00")), ("o2", 1, "not_defined", 1, Decimal("0.00"))],
        ["order_id", "payment_sequential", "payment_type", "payment_installments", "payment_value"],
    )
    assert rows(olist.order_payments(raw), "order_id", "payment_type") == [("o1", "credit_card"), ("o2", "unknown")]


def test_order_reviews_keeps_latest_answer_and_flattens_comments(frame):
    raw = frame(
        [
            ("r1", "o1", 5, "", "Muito bom\r\nchegou rápido", datetime(2018, 1, 1), datetime(2018, 1, 2)),
            ("r1", "o1", 4, "", "", datetime(2018, 1, 1), datetime(2018, 1, 3)),
            ("r1", "o2", 1, "Ruim", None, datetime(2018, 1, 1), datetime(2018, 1, 2)),
        ],
        [
            "review_id", "order_id", "review_score", "review_comment_title", "review_comment_message",
            "review_creation_date", "review_answer_timestamp",
        ],
    )
    out = olist.order_reviews(raw)
    assert rows(out, "order_id", "review_score", "comment_message", "has_comment") == [
        ("o1", 4, None, False),
        ("o2", 1, None, True),
    ]
    flat = olist.order_reviews(raw.filter("review_score = 5"))
    assert rows(flat, "order_id", "comment_message") == [("o1", "Muito bom chegou rápido")]


def test_geolocation_one_row_per_zip_inside_brazil(frame):
    raw = frame(
        [
            ("01037", -23.54, -46.63, "são paulo", "SP"),
            ("01037", -23.56, -46.65, "sao paulo", "SP"),
            ("01037", -23.55, -46.64, "osasco", "SP"),
            ("01037", 40.0, -3.7, "madrid", "SP"),  # outside Brazil
        ],
        ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng", "geolocation_city", "geolocation_state"],
    )
    out = olist.geolocation(raw)
    [row] = out.collect()
    assert (row["zip_code_prefix"], row["city"], row["state"], row["points"]) == ("01037", "sao paulo", "SP", 3)
    assert -23.56 <= row["lat"] <= -23.54


def test_order_events_dedupe_and_current_status(frame):
    columns = [
        "event_id", "event_type", "event_time", "order_id", "customer_id", "final_order_status",
        "estimated_delivery_date", "produced_at",
    ]
    base = [
        ("e1", "ORDER_PURCHASED", "2018-01-01 10:00:00", "o1", "c1", "canceled", "2018-01-10 00:00:00", "2026-11-03T10:00:00+00:00"),
        ("e2", "ORDER_APPROVED", "2018-01-01 12:00:00", "o1", "c1", "canceled", "2018-01-10 00:00:00", "2026-11-03T10:00:00+00:00"),
        ("e3", "ORDER_CANCELED", "2018-01-01 12:00:00", "o1", "c1", "canceled", "2018-01-10 00:00:00", "2026-11-03T10:00:00+00:00"),
    ]
    replayed = frame(base + [base[0]], columns)  # e1 arrives twice
    events = olist.order_events(replayed)
    assert events.count() == 3
    current = olist.order_status_current(events)
    # Approved and canceled share a timestamp; the terminal event wins
    assert rows(current, "order_id", "last_event_type") == [("o1", "ORDER_CANCELED")]


def test_tpch_customer_types(frame):
    raw = frame(
        [(" 1 ", "Customer#000000001", "addr", "15", "25-989-741-2988", "711.56", "building", "c")],
        ["c_custkey", "c_name", "c_address", "c_nationkey", "c_phone", "c_acctbal", "c_mktsegment", "c_comment"],
    )
    [row] = tpch.tpch_customer(raw).collect()
    assert (row["c_custkey"], row["c_nationkey"], row["c_acctbal"], row["c_mktsegment"]) == (
        1, 15, Decimal("711.56"), "BUILDING",
    )


def test_quality_split_quarantines_with_reasons(table):
    orders = table([("o1", "c1", 5), ("o2", "c9", 5), (None, "c1", 7)], ["order_id", "customer_id", "score"])
    customers = table([("c1",)], ["customer_id"])
    flagged = quality.flag_reference(orders, "customer_id", customers, "customer_id", "_ref_customer")
    good, bad = quality.split(
        flagged,
        [
            ("key_missing", quality.not_null("order_id")),
            ("score_out_of_range", F.col("score").between(1, 5)),
            ("customer_not_found", F.col("_ref_customer")),
        ],
    )
    assert [r["order_id"] for r in good.collect()] == ["o1"]
    assert "_ref_customer" not in good.columns
    reasons = {r["customer_id"] + ":" + r["_dq_reason"] for r in bad.collect()}
    assert reasons == {"c9:customer_not_found", "c1:key_missing,score_out_of_range"}


def test_rules_accept_raw_strings(frame):
    """Raw keeps MySQL values as the strings of the landing CSV export."""
    orders_raw = frame(
        [("o1", "c1", "delivered", "2018-01-01 10:00:00", "2018-01-01 12:00:00", "2018-01-02 00:00:00", "2018-01-11 10:00:00", "2018-01-10 00:00:00")],
        [
            "order_id", "customer_id", "order_status", "order_purchase_timestamp", "order_approved_at",
            "order_delivered_carrier_date", "order_delivered_customer_date", "order_estimated_delivery_date",
        ],
    )
    assert rows(olist.orders(orders_raw), "order_id", "delivery_days", "is_late", "approval_hours") == [("o1", 10, True, 2.0)]

    items_raw = frame(
        [("o1", "1", "p1", "s1", "2018-01-05 00:00:00", "10.50", "2.25")],
        ["order_id", "order_item_id", "product_id", "seller_id", "shipping_limit_date", "price", "freight_value"],
    )
    assert rows(olist.order_items(items_raw), "order_item_id", "line_total") == [(1, Decimal("12.75"))]

    geo_raw = frame(
        [("1037", "-23.54", "-46.63", "sao paulo", "SP")],
        ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng", "geolocation_city", "geolocation_state"],
    )
    assert rows(olist.geolocation(geo_raw), "zip_code_prefix", "lat") == [("01037", -23.54)]


def test_quality_split_without_rules_keeps_every_row(table):
    good, bad = quality.split(table([("o1",), ("o2",)], ["order_id"]), [])
    assert (good.count(), bad.count()) == (2, 0)
    assert good.columns == ["order_id"]
