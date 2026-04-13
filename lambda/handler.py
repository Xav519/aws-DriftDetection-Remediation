"""
Drift Detection Lambda Handler
================================
Receives either:
  - A Terraform plan JSON uploaded to S3 by GitHub Actions (s3_bucket + s3_key)
  - A Terraform plan JSON (base64-encoded) passed directly (legacy fallback)
  - An EventBridge scheduled trigger (runs a lightweight classification of
    the latest plan stored in S3)
Responsibilities:
  1. Parse terraform show -json output
  2. Classify each resource change by severity
  3. Write drift events to DynamoDB with TTL
  4. Publish SNS alert if any drift found
  5. Emit CloudWatch custom metrics
  6. Create structured log entries for CloudWatch Insights queries
"""
import json
import os
import base64
import logging
import hashlib
from datetime import datetime, timezone, timedelta
from typing import Any
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients
dynamodb = boto3.resource("dynamodb")
sns_client = boto3.client("sns")
cloudwatch = boto3.client("cloudwatch")
s3_client = boto3.client("s3")

# Environment config
DRIFT_TABLE_NAME = os.environ["DRIFT_TABLE_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
AUTO_REMEDIATE_ENABLED = os.environ.get("AUTO_REMEDIATE_ENABLED", "false").lower() == "true"

# Severity classification rules
# Each entry: (resource_type_prefix, attribute_name_pattern, severity)
SEVERITY_RULES: list[tuple[str, str, str]] = [
    # IAM — always critical
    ("aws_iam_", "", "CRITICAL"),
    # Security Group open ingress
    ("aws_security_group", "ingress", "CRITICAL"),
    ("aws_security_group_rule", "cidr_blocks", "CRITICAL"),
    # S3 encryption / public access
    ("aws_s3_bucket_server_side_encryption", "", "CRITICAL"),
    ("aws_s3_bucket_public_access_block", "block_public", "CRITICAL"),
    # S3 bucket policy
    ("aws_s3_bucket_policy", "", "HIGH"),
    # Instance type / size changes
    ("aws_instance", "instance_type", "HIGH"),
    ("aws_db_instance", "instance_class", "HIGH"),
    # Encryption at rest
    ("", "encrypted", "HIGH"),
    ("", "kms_key_id", "HIGH"),
    # Default: tag / description changes
    ("", "tags", "LOW"),
    ("", "description", "LOW"),
]

TTL_DAYS = 90


def lambda_handler(event: dict, context: Any) -> dict:
    """Entry point — handles both direct invocation and EventBridge scheduled triggers."""
    logger.info("Drift parser invoked. Event source: %s", event.get("source", "direct"))

    plan_json = _extract_plan(event)
    if not plan_json:
        logger.info("No plan data in event — nothing to parse (scheduled ping or test)")
        return {"statusCode": 200, "body": "no_plan_data"}

    drift_events = parse_plan(plan_json)
    if not drift_events:
        logger.info("No drift detected. Infrastructure matches desired state.")
        _emit_metric("DriftEventsTotal", 0)
        return {"statusCode": 200, "body": "no_drift", "drift_count": 0}

    logger.info("Drift detected. %d resource(s) out of state.", len(drift_events))
    written = write_drift_events(drift_events)
    publish_alert(drift_events)
    emit_metrics(drift_events)

    return {
        "statusCode": 200,
        "body": "drift_detected",
        "drift_count": len(drift_events),
        "critical_count": sum(1 for e in drift_events if e["severity"] == "CRITICAL"),
        "written_to_dynamo": written,
    }


def _extract_plan(event: dict) -> dict | None:
    """
    Extract terraform plan JSON from event payload.
    Priority order:
      1. S3 reference (s3_bucket + s3_key) — used by GitHub Actions to avoid
         OS argument length limits when the plan JSON is large
      2. Inline base64 (plan_json_b64) — legacy fallback
      3. Raw embedded JSON (plan_json)
      4. Scheduled trigger — returns None
    """
    # 1. S3 reference — fetch plan from S3
    if "s3_bucket" in event and "s3_key" in event:
        try:
            logger.info(
                "Fetching plan from S3: s3://%s/%s",
                event["s3_bucket"], event["s3_key"]
            )
            obj = s3_client.get_object(
                Bucket=event["s3_bucket"],
                Key=event["s3_key"]
            )
            return json.loads(obj["Body"].read().decode("utf-8"))
        except Exception as e:
            logger.error("Failed to fetch plan from S3: %s", e)
            return None

    # 2. Inline base64-encoded plan (legacy)
    if "plan_json_b64" in event:
        try:
            decoded = base64.b64decode(event["plan_json_b64"]).decode("utf-8")
            return json.loads(decoded)
        except Exception as e:
            logger.error("Failed to decode plan_json_b64: %s", e)
            return None

    # 3. Raw plan JSON embedded directly
    if "plan_json" in event:
        return event["plan_json"]

    # 4. Scheduled trigger — no plan attached
    return None


def parse_plan(plan: dict) -> list[dict]:
    """
    Parse terraform show -json output and return a list of drift events.
    Each event contains resource metadata + classified severity.
    """
    drift_events = []
    resource_changes = plan.get("resource_changes", [])

    for change in resource_changes:
        actions = change.get("change", {}).get("actions", [])
        if actions == ["no-op"] or not actions:
            continue

        resource_address = change.get("address", "unknown")
        resource_type = change.get("type", "")
        change_before = change.get("change", {}).get("before") or {}
        change_after = change.get("change", {}).get("after") or {}
        changed_attrs = _diff_attributes(change_before, change_after)
        severity = _classify_severity(resource_type, changed_attrs)
        change_type = _classify_change_type(actions)

        event = {
            "resource_address": resource_address,
            "resource_type": resource_type,
            "change_type": change_type,
            "severity": severity,
            "changed_attributes": changed_attrs,
            "detected_at": datetime.now(timezone.utc).isoformat(),
            "environment": ENVIRONMENT,
            "plan_hash": _hash_change(change),
        }

        logger.info(
            "DRIFT_EVENT resource_address=%s severity=%s change_type=%s resource_type=%s",
            resource_address, severity, change_type, resource_type,
            extra={"json_fields": event},
        )
        drift_events.append(event)

    return drift_events


def _normalize(v):
    if v in ("", None, {}, []):
        return None

    if isinstance(v, list):
        cleaned = [_normalize(i) for i in v]
        cleaned = [i for i in cleaned if i is not None]
        return cleaned or None

    if isinstance(v, dict):
        return {k: _normalize(val) for k, val in v.items()}

    return v


def _diff_attributes(before: dict, after: dict) -> dict:
    changed = {}
    all_keys = set(before.keys()) | set(after.keys())

    for key in all_keys:
        v_before = _normalize(before.get(key))
        v_after = _normalize(after.get(key))

        # extra safety: treat empty lists as equal
        if v_before == []:
            v_before = None
        if v_after == []:
            v_after = None

        if v_before != v_after:
            changed[key] = {"before": v_before, "after": v_after}

    return changed


def _classify_severity(resource_type: str, changed_attrs: dict) -> str:
    """
    Apply severity rules. Returns CRITICAL / HIGH / MEDIUM / LOW.
    Rules are evaluated top-to-bottom; first match wins.
    """
    attr_names = list(changed_attrs.keys())
    for type_prefix, attr_pattern, severity in SEVERITY_RULES:
        type_match = not type_prefix or resource_type.startswith(type_prefix)
        attr_match = not attr_pattern or any(attr_pattern in a for a in attr_names)
        if type_match and attr_match:
            return severity
    return "MEDIUM"


def _classify_change_type(actions: list[str]) -> str:
    if "delete" in actions and "create" in actions:
        return "replace"
    if "delete" in actions:
        return "delete"
    if "create" in actions:
        return "create"
    return "update"


def _hash_change(change: dict) -> str:
    """Deterministic hash of a resource change — used for deduplication."""
    serialized = json.dumps(change, sort_keys=True).encode()
    return hashlib.sha256(serialized).hexdigest()[:16]


def write_drift_events(events: list[dict]) -> int:
    """Batch-write drift events to DynamoDB with 90-day TTL."""
    table = dynamodb.Table(DRIFT_TABLE_NAME)
    expires_at = int((datetime.now(timezone.utc) + timedelta(days=TTL_DAYS)).timestamp())
    written = 0

    for event in events:
        try:
            table.put_item(
                Item={
                    **event,
                    "expires_at": expires_at,
                    "changed_attributes": json.dumps(event["changed_attributes"]),
                },
                ConditionExpression="attribute_not_exists(resource_address) OR #da <> :da",
                ExpressionAttributeNames={"#da": "detected_at"},
                ExpressionAttributeValues={":da": event["detected_at"]},
            )
            written += 1
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                logger.debug("Duplicate drift event skipped: %s", event["resource_address"])
            else:
                logger.error("DynamoDB write failed: %s", e)

    logger.info("Wrote %d/%d drift events to DynamoDB", written, len(events))
    return written


def publish_alert(events: list[dict]) -> None:
    """Publish a drift alert to SNS. One message per severity tier."""
    critical = [e for e in events if e["severity"] == "CRITICAL"]
    others = [e for e in events if e["severity"] != "CRITICAL"]

    def _publish(event_list: list[dict], subject_prefix: str) -> None:
        if not event_list:
            return
        summary = {
            "severity_summary": _count_by_severity(event_list),
            "total_drifted_resources": len(event_list),
            "environment": ENVIRONMENT,
            "detected_at": datetime.now(timezone.utc).isoformat(),
            "events": [
                {
                    "resource_address": e["resource_address"],
                    "severity": e["severity"],
                    "change_type": e["change_type"],
                    "details": e["changed_attributes"],
                }
                for e in event_list[:10]
            ],
        }
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[{subject_prefix}] {ENVIRONMENT.upper()} — {len(event_list)} resource(s) drifted",
            Message=json.dumps(summary, indent=2),
            MessageAttributes={
                "severity": {"DataType": "String", "StringValue": subject_prefix},
                "environment": {"DataType": "String", "StringValue": ENVIRONMENT},
            },
        )

    if critical:
        _publish(critical, "CRITICAL DRIFT")
    if others:
        _publish(others, "DRIFT DETECTED")


def emit_metrics(events: list[dict]) -> None:
    """Push custom CloudWatch metrics for the dashboard."""
    counts = _count_by_severity(events)
    namespace = "DriftDetection"
    dims = [{"Name": "Environment", "Value": ENVIRONMENT}]

    metric_data = [
        {"MetricName": "DriftEventsTotal",   "Value": len(events),               "Unit": "Count", "Dimensions": dims},
        {"MetricName": "CriticalDriftCount", "Value": counts.get("CRITICAL", 0), "Unit": "Count", "Dimensions": dims},
        {"MetricName": "HighDriftCount",     "Value": counts.get("HIGH", 0),     "Unit": "Count", "Dimensions": dims},
        {"MetricName": "MediumDriftCount",   "Value": counts.get("MEDIUM", 0),   "Unit": "Count", "Dimensions": dims},
        {"MetricName": "LowDriftCount",      "Value": counts.get("LOW", 0),      "Unit": "Count", "Dimensions": dims},
    ]
    cloudwatch.put_metric_data(Namespace=namespace, MetricData=metric_data)
    logger.info("Published %d custom metrics to CloudWatch", len(metric_data))


def _emit_metric(name: str, value: float) -> None:
    cloudwatch.put_metric_data(
        Namespace="DriftDetection",
        MetricData=[{
            "MetricName": name,
            "Value": value,
            "Unit": "Count",
            "Dimensions": [{"Name": "Environment", "Value": ENVIRONMENT}],
        }]
    )


def _count_by_severity(events: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for e in events:
        counts[e["severity"]] = counts.get(e["severity"], 0) + 1
    return counts
