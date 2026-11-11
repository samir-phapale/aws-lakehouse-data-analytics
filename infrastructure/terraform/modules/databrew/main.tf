# DataBrew cannot read Delta, so each dataset is the Parquet snapshot the transformed job writes
# to _dq/<table>/. hashicorp/aws has no DataBrew resources, hence awscc.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    awscc = {
      source = "hashicorp/awscc"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

resource "aws_iam_role" "databrew" {
  name = "${var.name_prefix}-databrew-role"

  # No aws:SourceAccount condition: with it, job creation fails with "DataBrew is not a trusted entity"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "databrew.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-databrew-role"
  }
}

data "aws_iam_policy_document" "databrew" {
  statement {
    sid       = "TransformedList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.transformed_bucket_name}"]
  }

  statement {
    sid       = "SnapshotRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.transformed_bucket_name}/_dq/*"]
  }

  statement {
    sid     = "ReportWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.transformed_bucket_name}/_dq_reports/*",
      "arn:aws:s3:::${var.transformed_bucket_name}/_dq_reports_$folder$",
    ]
  }

  statement {
    sid       = "KmsUse"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws-glue-databrew/*"]
  }
}

resource "aws_iam_role_policy" "databrew" {
  name   = "${var.name_prefix}-databrew-policy"
  role   = aws_iam_role.databrew.id
  policy = data.aws_iam_policy_document.databrew.json
}

# Job creation checks the role's trust policy and fails until the new role has propagated
resource "time_sleep" "role_propagation" {
  create_duration = "30s"

  triggers = {
    role_arn = aws_iam_role.databrew.arn
    policy   = aws_iam_role_policy.databrew.id
  }
}

# DataBrew names allow no underscores
resource "awscc_databrew_dataset" "table" {
  for_each = local.rulesets

  name   = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  format = "PARQUET"

  input = {
    s3_input_definition = {
      bucket = var.transformed_bucket_name
      key    = "_dq/${each.key}/"
    }
  }
}

# DataBrew will not create a job over an empty dataset folder. The seed is put once (not an
# aws_s3_object, which would come back every apply) and the transformed job's overwrite deletes it.
resource "terraform_data" "dataset_seed" {
  for_each = local.rulesets

  triggers_replace = [awscc_databrew_dataset.table[each.key].id]

  provisioner "local-exec" {
    command = "aws s3api put-object --bucket ${var.transformed_bucket_name} --key _dq/${each.key}/_seed --region ${var.region}"
  }
}

resource "awscc_databrew_ruleset" "table" {
  for_each = local.rulesets

  name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description = "Data-quality rules for transformed.${each.key}"
  target_arn  = "arn:aws:databrew:${var.region}:${var.account_id}:dataset/${awscc_databrew_dataset.table[each.key].name}"

  rules = [for rule in each.value : {
    name             = rule.name
    check_expression = rule.check
    substitution_map = [for ref, value in rule.values : { value_reference = ref, value = value }]
    column_selectors = try([for column in rule.columns : { name = column }], null)
    threshold = try({
      value = rule.threshold
      type  = "GREATER_THAN_OR_EQUAL"
      unit  = "PERCENTAGE"
    }, null)
  }]
}

resource "awscc_databrew_job" "profile" {
  for_each = local.rulesets

  name               = "${var.name_prefix}-dq-${replace(each.key, "_", "-")}"
  type               = "PROFILE"
  dataset_name       = awscc_databrew_dataset.table[each.key].name
  role_arn           = time_sleep.role_propagation.triggers["role_arn"]
  max_capacity       = 2
  timeout            = 30
  encryption_mode    = "SSE-KMS"
  encryption_key_arn = var.kms_key_arn

  job_sample = {
    mode = "FULL_DATASET"
  }

  output_location = {
    bucket = var.transformed_bucket_name
    key    = "_dq_reports/${each.key}/"
  }

  validation_configurations = [{
    ruleset_arn     = "arn:aws:databrew:${var.region}:${var.account_id}:ruleset/${awscc_databrew_ruleset.table[each.key].name}"
    validation_mode = "CHECK_ALL"
  }]

  depends_on = [terraform_data.dataset_seed]
}
