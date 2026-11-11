"""Data-quality gate for the Step Functions pipeline.

A DataBrew profile job succeeds even when ruleset rules fail; the verdict is only in the validation
report it writes, so this reads the report and returns pass/fail for the table. The report keys come
from the job run's Outputs (the file names use a hash, not the run id).

Event:  {"table", "bucket", "report_keys"}
Result: {"table", "passed", "failed_rules", "report_key"}
"""

import json
import os

import boto3

REPORT_SUFFIX = "dq-validation-report.json"

# Explicit region so the module also imports where no default region is configured (unit tests)
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"))


def failed_rules(node):
    """Names of every rule or ruleset marked FAILED anywhere in the report."""
    if isinstance(node, list):
        return [name for item in node for name in failed_rules(item)]
    if not isinstance(node, dict):
        return []

    failed = []
    status = node.get("status") or node.get("Status")
    if isinstance(status, str) and status.upper() == "FAILED":
        failed.append(node.get("name") or node.get("Name") or node.get("rulesetName") or "unnamed")
    for value in node.values():
        failed.extend(failed_rules(value))
    return failed


def handler(event, _context):
    table, bucket = event["table"], event["bucket"]
    key = next((k for k in event.get("report_keys", []) if k.endswith(REPORT_SUFFIX)), None)
    if key is None:
        return {"table": table, "passed": False, "failed_rules": ["validation report not found"], "report_key": None}

    report = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    failed = failed_rules(report)
    print(json.dumps({"table": table, "report_key": key, "failed_rules": failed}))
    return {"table": table, "passed": not failed, "failed_rules": failed, "report_key": key}
