"""Replay Olist order lifecycles to the MSK topic as JSON events (run on the EC2 producer over SSM).

event_id is uuid5(order_id, event_type), so replays repeat ids and transformed can drop duplicates.
"""

import argparse
import csv
import json
import time
import uuid
from datetime import datetime, timezone

from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaProducer
from kafka.admin import KafkaAdminClient, NewTopic
from kafka.errors import TopicAlreadyExistsError
from kafka.sasl.oauth import AbstractTokenProvider  # module path as of the pinned kafka-python 2.3

# Lifecycle steps in order, with the orders column holding when each happened
LIFECYCLE = [
    ("ORDER_PURCHASED", "order_purchase_timestamp"),
    ("ORDER_APPROVED", "order_approved_at"),
    ("ORDER_SHIPPED", "order_delivered_carrier_date"),
    ("ORDER_DELIVERED", "order_delivered_customer_date"),
]
TERMINAL_STATUSES = {"canceled": "ORDER_CANCELED", "unavailable": "ORDER_UNAVAILABLE"}
EVENT_ID_NAMESPACE = uuid.UUID("6f1c3a52-3c55-4a8e-9a43-0d6c1c7f2b10")


class MskIamTokenProvider(AbstractTokenProvider):
    def __init__(self, region):
        self.region = region

    def token(self):
        token, _expiry_ms = MSKAuthTokenProvider.generate_auth_token(self.region)
        return token


def client_config(bootstrap, region):
    return {
        "bootstrap_servers": bootstrap.split(","),
        "security_protocol": "SASL_SSL",
        "sasl_mechanism": "OAUTHBEARER",
        "sasl_oauth_token_provider": MskIamTokenProvider(region),
        "client_id": "lakehouse-order-events-producer",
    }


def ensure_topic(config, topic, partitions, replication):
    admin = KafkaAdminClient(**config)
    try:
        admin.create_topics([NewTopic(topic, partitions, replication)])
        print(f"Created topic {topic}")
    except TopicAlreadyExistsError:
        print(f"Topic {topic} already exists")
    finally:
        admin.close()


def order_events(order):
    """Events for one order, oldest first. Steps with no timestamp did not happen."""
    events = []
    last_time = None
    for event_type, column in LIFECYCLE:
        if order[column]:
            last_time = order[column]
            events.append((event_type, last_time))
    terminal = TERMINAL_STATUSES.get(order["order_status"])
    if terminal and last_time:
        events.append((terminal, last_time))

    return [
        {
            "event_id": str(uuid.uuid5(EVENT_ID_NAMESPACE, f"{order['order_id']}:{event_type}")),
            "event_type": event_type,
            "event_time": event_time,
            "order_id": order["order_id"],
            "customer_id": order["customer_id"],
            # Known only in hindsight; handy for testing the transformed zone
            "final_order_status": order["order_status"],
            "estimated_delivery_date": order["order_estimated_delivery_date"] or None,
            "produced_at": datetime.now(timezone.utc).isoformat(),
        }
        for event_type, event_time in events
    ]


def load_events(path, offset, count):
    with open(path, encoding="utf-8-sig", newline="") as f:
        orders = sorted(csv.DictReader(f), key=lambda o: o["order_purchase_timestamp"])
    selected = orders[offset:] if count == 0 else orders[offset : offset + count]
    events = [event for order in selected for event in order_events(order)]
    # Replay in the order things happened across all selected orders
    return len(selected), sorted(events, key=lambda e: e["event_time"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", required=True, help="MSK SASL/IAM bootstrap brokers")
    parser.add_argument("--topic", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--orders-file", required=True, help="path to olist_orders_dataset.csv")
    parser.add_argument("--count", type=int, default=500, help="orders to replay (0 = all)")
    parser.add_argument("--offset", type=int, default=0, help="skip the first N orders by purchase time")
    parser.add_argument("--rate", type=float, default=50, help="events per second")
    parser.add_argument("--partitions", type=int, default=2)
    parser.add_argument("--replication", type=int, default=2)
    args = parser.parse_args()

    order_count, events = load_events(args.orders_file, args.offset, args.count)
    print(f"Replaying {len(events)} events from {order_count} orders")

    config = client_config(args.bootstrap, args.region)
    ensure_topic(config, args.topic, args.partitions, args.replication)

    producer = KafkaProducer(
        **config,
        acks="all",
        key_serializer=lambda key: key.encode("utf-8"),
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
    )
    for sent, event in enumerate(events, start=1):
        # Keyed by order so one order's events stay in order on one partition
        producer.send(args.topic, key=event["order_id"], value=event)
        if sent % 1000 == 0:
            print(f"Sent {sent} events")
        time.sleep(1 / args.rate)
    producer.flush()
    producer.close()
    print(f"Done: sent {len(events)} events to {args.topic}")


if __name__ == "__main__":
    main()
