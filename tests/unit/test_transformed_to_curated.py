"""Unit tests for the transformed -> curated rules (src/transformations/transformed_to_curated)."""

from datetime import date, datetime
from decimal import Decimal

import curated_transforms as c

ORDER_COLUMNS = [
    "order_id", "customer_id", "order_status", "purchased_at", "purchase_date",
    "delivered_at", "estimated_delivery_at", "delivery_days", "is_late", "approval_hours",
]


def rows(frame, *columns):
    return [tuple(r[col] for col in columns) for r in frame.orderBy(*columns).collect()]


def orders(table):
    ts = datetime
    return table(
        [
            ("o1", "c1", "delivered", ts(2018, 1, 1, 10), date(2018, 1, 1), ts(2018, 1, 5), ts(2018, 1, 10), 4, False, 1.0),
            ("o2", "c2", "delivered", ts(2018, 1, 3, 10), date(2018, 1, 3), ts(2018, 1, 20), ts(2018, 1, 10), 17, True, 2.0),
            ("o3", "c3", "canceled", ts(2018, 1, 3, 12), date(2018, 1, 3), None, ts(2018, 1, 10), None, None, None),
        ],
        ORDER_COLUMNS,
    )


def customers(table):
    return table(
        [("c1", "u1", "01037", "sao paulo", "SP"), ("c2", "u1", "20000", "rio de janeiro", "RJ"), ("c3", "u2", "69000", "manaus", "AM")],
        ["customer_id", "customer_unique_id", "zip_code_prefix", "city", "state"],
    )


def order_items(table):
    d = Decimal
    return table(
        [
            ("o1", 1, "p1", "s1", d("10.00"), d("2.00"), d("12.00")),
            ("o1", 2, "p2", "s2", d("20.00"), d("3.00"), d("23.00")),
            ("o2", 1, "p1", "s1", d("10.00"), d("5.00"), d("15.00")),
        ],
        ["order_id", "order_item_id", "product_id", "seller_id", "price", "freight_value", "line_total"],
    )


def test_dim_date_covers_every_purchase_day(table):
    out = c.dim_date(orders(table))
    assert rows(out, "date_key", "day_of_week", "is_weekend") == [
        (20180101, 2, False),
        (20180102, 3, False),
        (20180103, 4, False),
    ]


def test_dim_customer_one_row_per_person_with_latest_address(table):
    out = c.dim_customer(customers(table), orders(table))
    assert rows(out, "customer_unique_id", "state", "region", "order_count", "is_repeat_customer") == [
        ("u1", "RJ", "SE", 2, True),
        ("u2", "AM", "N", 1, False),
    ]


def test_dim_product_bands(table):
    products = table(
        [("p1", "a", "a_en", 1, 300, 800), ("p2", "b", "b_en", 2, 6000, 50000), ("p3", "c", "c_en", 1, None, None)],
        ["product_id", "category", "category_en", "photos_qty", "weight_g", "volume_cm3"],
    )
    out = c.dim_product(products)
    assert rows(out, "product_id", "weight_band", "size_band") == [
        ("p1", "light (<0.5 kg)", "small (<1 L)"),
        ("p2", "heavy (5 kg+)", "large (20 L+)"),
        ("p3", "unknown", "unknown"),
    ]


def test_fact_orders_totals_payments_and_reviews(table):
    payments = table(
        [("o1", 1, "credit_card", 3, Decimal("30.00")), ("o1", 2, "voucher", 1, Decimal("5.00"))],
        ["order_id", "payment_sequential", "payment_type", "payment_installments", "payment_value"],
    )
    reviews = table([("r1", "o1", 5), ("r2", "o2", 1)], ["review_id", "order_id", "review_score"])
    out = c.fact_orders(orders(table), customers(table), order_items(table), payments, reviews)
    assert rows(out, "order_id", "customer_unique_id", "items_count", "order_total", "payment_value", "payment_type", "days_late") == [
        ("o1", "u1", 2, Decimal("35.00"), Decimal("35.00"), "credit_card", -5),
        ("o2", "u1", 1, Decimal("15.00"), None, None, 10),
        ("o3", "u2", 0, None, None, None, None),
    ]


def test_review_vs_delivery_buckets(table):
    fact = table(
        [("o1", 4, -5, 5.0), ("o2", 17, 10, 1.0), ("o3", 5, 2, 2.0), ("o4", None, None, 1.0)],
        ["order_id", "delivery_days", "days_late", "review_score"],
    )
    out = c.agg_review_vs_delivery(fact)
    assert rows(out, "bucket_order", "delivery_bucket", "orders", "bad_review_ratio") == [
        (1, "on time", 1, 0.0),
        (2, "1-3 days late", 1, 1.0),
        (4, "8+ days late", 1, 1.0),
        (5, "not delivered", 1, 1.0),
    ]


def test_seller_performance_per_month(table):
    items = c.fact_order_items(order_items(table), orders(table), customers(table))
    fact = table([("o1", 5.0), ("o2", 1.0)], ["order_id", "review_score"])
    out = c.agg_seller_performance(items, fact)
    assert rows(out, "seller_id", "month", "gmv", "orders", "avg_review_score", "late_ratio") == [
        ("s1", date(2018, 1, 1), Decimal("27.00"), 2, 3.0, 0.5),
        ("s2", date(2018, 1, 1), Decimal("23.00"), 1, 5.0, 0.0),
    ]


def test_payment_mix_counts_every_payment(table):
    payments = table(
        [
            ("o1", 1, "credit_card", 3, Decimal("30.00")),
            ("o1", 2, "voucher", 1, Decimal("5.00")),
            ("o2", 1, "credit_card", 1, Decimal("15.00")),
        ],
        ["order_id", "payment_sequential", "payment_type", "payment_installments", "payment_value"],
    )
    out = c.agg_payment_mix(payments)
    assert rows(out, "payment_type", "orders", "payments", "payment_value", "avg_installments") == [
        ("credit_card", 2, 2, Decimal("45.00"), 2.0),
        ("voucher", 1, 1, Decimal("5.00"), 1.0),
    ]


def test_tpch_segment_names_nations(table):
    tpch = table(
        [(1, 2, "BUILDING", Decimal("100.00")), (2, 2, "BUILDING", Decimal("-50.00")), (3, 24, "MACHINERY", Decimal("10.00"))],
        ["c_custkey", "c_nationkey", "c_mktsegment", "c_acctbal"],
    )
    out = c.agg_tpch_customer_segment(tpch)
    assert rows(out, "c_mktsegment", "nation", "customers", "negative_balance_ratio") == [
        ("BUILDING", "BRAZIL", 2, 0.5),
        ("MACHINERY", "UNITED STATES", 1, 0.0),
    ]
