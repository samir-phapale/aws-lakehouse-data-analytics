"""Data-quality gate for the Step Functions pipeline.

A DataBrew profile job succeeds even when ruleset rules fail; the verdict is only in the validation
report it writes, so this reads the report and returns pass/fail for the table. The report keys come
from the job run's Outputs (the file names use a hash, not the run id).

Fails closed: the table passes only if the report has at least one rule result and every status in it
is SUCCEEDED.

Event:  {"table", "bucket", "report_keys"}
Result: {"table", "passed", "failed_rules", "report_key"}
"""

import json
import os

import boto3

REPORT_SUFFIX = "dq-validation-report.json"
PASSED = "SUCCEEDED"

# Explicit region so the module also imports where no default region is configured (unit tests)
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"))


def statuses(node):
    """(name, status) for every rule or ruleset that carries a status anywhere in the report."""
    if isinstance(node, list):
        return [found for item in node for found in statuses(item)]
    if not isinstance(node, dict):
        return []

    found = []
    if "status" in node or "Status" in node:
        status = node.get("status") or node.get("Status")
        name = node.get("name") or node.get("Name") or node.get("rulesetName") or "unnamed"
        found.append((name, str(status).upper() if status else "MISSING"))
    for value in node.values():
        found.extend(statuses(value))
    return found


def rule_count(node):
    """Number of entries in every ruleResults list in the report."""
    if isinstance(node, list):
        return sum(rule_count(item) for item in node)
    if not isinstance(node, dict):
        return 0
    rules = node.get("ruleResults") or node.get("RuleResults")
    own = len(rules) if isinstance(rules, list) else 0
    return own + sum(rule_count(value) for value in node.values())


def verdict(report):
    """Names of the rules that did not succeed; empty only when the report shows a clean pass."""
    if rule_count(report) == 0:
        return ["no rule results in report"]
    return [name if status == "FAILED" else f"{name} ({status})" for name, status in statuses(report) if status != PASSED]


def handler(event, _context):
    table, bucket = event["table"], event["bucket"]
    key = next((k for k in event.get("report_keys", []) if k.endswith(REPORT_SUFFIX)), None)
    if key is None:
        return {"table": table, "passed": False, "failed_rules": ["validation report not found"], "report_key": None}

    report = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    failed = verdict(report)
    print(json.dumps({"table": table, "report_key": key, "failed_rules": failed}))
    return {"table": table, "passed": not failed, "failed_rules": failed, "report_key": key}
