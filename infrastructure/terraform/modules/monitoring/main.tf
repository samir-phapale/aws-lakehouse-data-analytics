# Config, GuardDuty and Security Hub are account-wide (Control Tower) and not owned here, so a
# destroy does not switch them off; this module only adds rules, remediation and alerts on top.

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "EventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Change-triggered rules only: Config ignores the tag scope on periodic rules (KMS rotation is
# enforced by the OPA policies instead)

locals {
  config_rules = {
    "s3-sse-kms"               = { identifier = "S3_DEFAULT_ENCRYPTION_KMS" }
    "s3-tls-only"              = { identifier = "S3_BUCKET_SSL_REQUESTS_ONLY" }
    "s3-public-access-blocked" = { identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED" }
    "s3-versioning"            = { identifier = "S3_BUCKET_VERSIONING_ENABLED" }
    "rds-encrypted"            = { identifier = "RDS_STORAGE_ENCRYPTED" }
    "rds-not-public"           = { identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK" }
    "msk-in-cluster-tls"       = { identifier = "MSK_IN_CLUSTER_NODE_REQUIRE_TLS" }
  }
}

resource "aws_config_config_rule" "this" {
  for_each = local.config_rules

  name        = "${var.name_prefix}-${each.key}"
  description = "Lakehouse detective control (${each.value.identifier}) on resources tagged Project=${var.project_tag}"

  source {
    owner             = "AWS"
    source_identifier = each.value.identifier
  }

  # Config rejects tag + resource-type scope together; each managed rule already targets its own type
  scope {
    tag_key   = "Project"
    tag_value = var.project_tag
  }
}

resource "aws_iam_role" "remediation" {
  name = "${var.name_prefix}-config-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ssm.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-config-remediation-role"
  }
}

data "aws_iam_policy_document" "remediation" {
  statement {
    sid    = "FixLakehouseBuckets"
    effect = "Allow"
    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
    ]
    resources = ["arn:aws:s3:::${var.bucket_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "remediation" {
  name   = "${var.name_prefix}-config-remediation-policy"
  role   = aws_iam_role.remediation.id
  policy = data.aws_iam_policy_document.remediation.json
}

resource "aws_config_remediation_configuration" "public_access" {
  config_rule_name           = aws_config_config_rule.this["s3-public-access-blocked"].name
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }
  # Same order as AWS returns them (alphabetical), or every plan shows a diff
  parameter {
    name         = "BlockPublicAcls"
    static_value = "true"
  }
  parameter {
    name         = "BlockPublicPolicy"
    static_value = "true"
  }
  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }
  parameter {
    name         = "IgnorePublicAcls"
    static_value = "true"
  }
  parameter {
    name         = "RestrictPublicBuckets"
    static_value = "true"
  }
}

resource "aws_config_remediation_configuration" "versioning" {
  config_rule_name           = aws_config_config_rule.this["s3-versioning"].name
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWS-ConfigureS3BucketVersioning"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }
  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }
  parameter {
    name         = "VersioningState"
    static_value = "Enabled"
  }
}

locals {
  alert_rules = {
    config-noncompliant = {
      description = "A lakehouse Config rule found a non-compliant resource"
      pattern = {
        source      = ["aws.config"]
        detail-type = ["Config Rules Compliance Change"]
        detail = {
          configRuleName      = [{ prefix = "${var.name_prefix}-" }]
          newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
        }
      }
    }
    guardduty-buckets = {
      description = "GuardDuty finding on a lakehouse bucket"
      pattern = {
        source      = ["aws.guardduty"]
        detail-type = ["GuardDuty Finding"]
        detail      = { resource = { s3BucketDetails = { name = [{ prefix = "${var.bucket_prefix}-" }] } } }
      }
    }
    guardduty-instances = {
      description = "GuardDuty finding on a lakehouse EC2 instance"
      pattern = {
        source      = ["aws.guardduty"]
        detail-type = ["GuardDuty Finding"]
        detail      = { resource = { instanceDetails = { tags = { value = [{ prefix = "${var.name_prefix}-" }] } } } }
      }
    }
    securityhub-failed = {
      description = "Security Hub failed control on a lakehouse resource"
      pattern = {
        source      = ["aws.securityhub"]
        detail-type = ["Security Hub Findings - Imported"]
        detail = {
          findings = {
            Compliance = { Status = ["FAILED"] }
            Resources  = { Id = [{ wildcard = "*${var.bucket_prefix}-*" }, { wildcard = "*${var.name_prefix}-*" }] }
            Workflow   = { Status = ["NEW"] }
          }
        }
      }
    }
    glue-job-failed = {
      description = "A lakehouse Glue job failed or timed out"
      pattern = {
        source      = ["aws.glue"]
        detail-type = ["Glue Job State Change"]
        detail      = { jobName = [{ prefix = "${var.name_prefix}-" }], state = ["FAILED", "TIMEOUT", "ERROR"] }
      }
    }
    pipeline-failed = {
      description = "The lakehouse Step Functions pipeline failed, timed out or was aborted"
      pattern = {
        source      = ["aws.states"]
        detail-type = ["Step Functions Execution Status Change"]
        detail      = { stateMachineArn = [{ prefix = "arn:aws:states:${var.region}:${var.account_id}:stateMachine:${var.name_prefix}-" }], status = ["FAILED", "TIMED_OUT", "ABORTED"] }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "alert" {
  for_each = local.alert_rules

  name          = "${var.name_prefix}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "alert" {
  for_each = local.alert_rules

  rule      = aws_cloudwatch_event_rule.alert[each.key].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}
