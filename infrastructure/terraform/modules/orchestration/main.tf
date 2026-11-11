terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

locals {
  glue_job_arn     = "arn:aws:glue:${var.region}:${var.account_id}:job/${var.name_prefix}-*"
  glue_crawler_arn = "arn:aws:glue:${var.region}:${var.account_id}:crawler/${var.name_prefix}-*"
  gate_name        = "${var.name_prefix}-dq-gate"

  external_schema_sql = trimspace(templatefile("${var.sql_dir}/01_external_schema.sql", {
    spectrum_database = var.spectrum_database
    role_arn          = var.redshift_role_arn
  }))

  # The Data API runs one statement per call: split on ";", drop comment lines and empty pieces
  load_marts_statements = [
    for statement in split(";", file("${var.sql_dir}/02_load_marts.sql")) :
    trimspace(join("\n", [for line in split("\n", statement) : line if !startswith(trimspace(line), "--")]))
  ]
  load_marts_sql = [for statement in local.load_marts_statements : statement if statement != ""]
}

data "archive_file" "gate" {
  type        = "zip"
  source_file = "${var.lambda_dir}/dq_gate/handler.py"
  output_path = "${path.module}/.build/dq_gate.zip"
}

resource "aws_iam_role" "gate" {
  name = "${local.gate_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${local.gate_name}-role"
  }
}

data "aws_iam_policy_document" "gate" {
  statement {
    sid       = "ReportRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.transformed_bucket_name}/_dq_reports/*"]
  }

  statement {
    sid       = "KmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.gate.arn}:*"]
  }
}

resource "aws_iam_role_policy" "gate" {
  name   = "${local.gate_name}-policy"
  role   = aws_iam_role.gate.id
  policy = data.aws_iam_policy_document.gate.json
}

resource "aws_cloudwatch_log_group" "gate" {
  name              = "/aws/lambda/${local.gate_name}"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "gate" {
  function_name    = local.gate_name
  description      = "Reads a DataBrew ruleset validation report and returns pass/fail"
  role             = aws_iam_role.gate.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.gate.output_path
  source_code_hash = data.archive_file.gate.output_base64sha256
  timeout          = 60
  memory_size      = 256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.gate.name
  }

  depends_on = [aws_iam_role_policy.gate]
}

resource "aws_iam_role" "pipeline" {
  name = "${var.name_prefix}-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-pipeline-role"
  }
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "GlueJobs"
    effect    = "Allow"
    actions   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
    resources = [local.glue_job_arn]
  }

  statement {
    sid       = "GlueCrawlers"
    effect    = "Allow"
    actions   = ["glue:StartCrawler", "glue:GetCrawler"]
    resources = [local.glue_crawler_arn]
  }

  statement {
    sid       = "DataSync"
    effect    = "Allow"
    actions   = ["datasync:StartTaskExecution", "datasync:DescribeTaskExecution"]
    resources = [var.datasync_task_arn, "${var.datasync_task_arn}/execution/*"]
  }

  statement {
    sid       = "DataBrewJobs"
    effect    = "Allow"
    actions   = ["databrew:StartJobRun", "databrew:ListJobRuns", "databrew:StopJobRun", "databrew:DescribeJobRun"]
    resources = var.databrew_job_arns
  }

  statement {
    sid       = "Gate"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.gate.arn]
  }

  statement {
    sid       = "RedshiftStatements"
    effect    = "Allow"
    actions   = ["redshift-data:ExecuteStatement", "redshift-data:BatchExecuteStatement"]
    resources = [var.redshift_workgroup_arn]
  }

  # Statement status calls are scoped by statement owner, not by resource
  statement {
    sid       = "RedshiftStatementStatus"
    effect    = "Allow"
    actions   = ["redshift-data:DescribeStatement"]
    resources = ["*"]
  }

  statement {
    sid       = "RedshiftSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.redshift_secret_arn]
  }

  statement {
    sid       = "Alerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }

  statement {
    sid       = "KmsForAlertsAndLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }

  # CloudWatch Logs delivery for Step Functions has no resource-level scoping
  statement {
    sid    = "ExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "${var.name_prefix}-pipeline-policy"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-pipeline"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.name_prefix}-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  definition = templatefile(var.asl_path, {
    dq_jobs                    = jsonencode([for table, job in var.databrew_jobs : { table = table, job = job }])
    crawlers                   = jsonencode(var.crawler_names)
    ingest_job                 = var.ingest_job_name
    datasync_task_arn          = var.datasync_task_arn
    landing_to_raw_job         = var.landing_to_raw_job_name
    raw_to_transformed_job     = var.raw_to_transformed_job_name
    transformed_to_curated_job = var.transformed_to_curated_job_name
    gate_function_arn          = aws_lambda_function.gate.arn
    transformed_bucket         = var.transformed_bucket_name
    redshift_workgroup         = var.redshift_workgroup_name
    redshift_database          = var.redshift_database
    redshift_secret_arn        = var.redshift_secret_arn
    external_schema_sql        = jsonencode(local.external_schema_sql)
    load_marts_sql             = jsonencode(local.load_marts_sql)
    alerts_topic_arn           = var.alerts_topic_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.pipeline.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  depends_on = [aws_iam_role_policy.pipeline]
}

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-pipeline-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-pipeline-scheduler-role"
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name_prefix}-pipeline-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.pipeline.arn
    }]
  })
}

resource "aws_scheduler_schedule" "pipeline" {
  name                         = "${var.name_prefix}-pipeline-daily"
  description                  = "Daily lakehouse batch run"
  schedule_expression          = "cron(0 3 * * ? *)"
  schedule_expression_timezone = "UTC"
  state                        = var.enable_schedule ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({})
  }
}
