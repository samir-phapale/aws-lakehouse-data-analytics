"""Unit tests for the DataBrew validation-report gate (orchestration/lambda/dq_gate)."""

import importlib.util
import io
import json
from pathlib import Path

import pytest

HANDLER = Path(__file__).resolve().parents[2] / "orchestration" / "lambda" / "dq_gate" / "handler.py"


@pytest.fixture
def gate():
    pytest.importorskip("boto3")
    spec = importlib.util.spec_from_file_location("dq_gate_handler", HANDLER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeS3:
    def __init__(self, objects):
        self.objects = objects

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(json.dumps(self.objects[Key]).encode())}


REPORT_KEY = "_dq_reports/orders/orders_123_dq-validation-report.json"
EVENT = {"table": "orders", "bucket": "b", "report_keys": ["_dq_reports/orders/orders_123.json", REPORT_KEY]}


def test_passes_when_every_rule_succeeded(gate, monkeypatch):
    report = {"rulesetResults": [{"status": "SUCCEEDED", "ruleResults": [{"name": "order_id unique", "status": "SUCCEEDED"}]}]}
    monkeypatch.setattr(gate, "s3", FakeS3({REPORT_KEY: report}))
    assert gate.handler(EVENT, None)["passed"] is True


def test_fails_and_names_the_failed_rules(gate, monkeypatch):
    report = {
        "rulesetResults": [
            {
                "status": "FAILED",
                "name": "lakehouse-dev-orders",
                "ruleResults": [
                    {"name": "order_id unique", "status": "SUCCEEDED"},
                    {"name": "status known", "status": "FAILED"},
                ],
            }
        ]
    }
    monkeypatch.setattr(gate, "s3", FakeS3({REPORT_KEY: report}))
    result = gate.handler(EVENT, None)
    assert result["passed"] is False
    assert "status known" in result["failed_rules"]


def test_missing_report_fails_closed(gate, monkeypatch):
    monkeypatch.setattr(gate, "s3", FakeS3({}))
    result = gate.handler({**EVENT, "report_keys": ["_dq_reports/orders/orders_123.json"]}, None)
    assert result["passed"] is False and result["report_key"] is None
