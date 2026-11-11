resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/datasync/${var.name_prefix}"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["datasync.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:datasync:${var.region}:${var.account_id}:task/*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "this" {
  policy_name     = "${var.name_prefix}-datasync-logs"
  policy_document = data.aws_iam_policy_document.logs.json
}

resource "aws_datasync_location_s3" "source" {
  s3_bucket_arn    = var.source_bucket_arn
  subdirectory     = "/${trim(var.source_prefix, "/")}/"
  s3_storage_class = "STANDARD"

  s3_config {
    bucket_access_role_arn = var.role_arn
  }

  tags = {
    Name = "${var.name_prefix}-source-files"
  }
}

resource "aws_datasync_location_s3" "landing" {
  s3_bucket_arn    = var.destination_bucket_arn
  subdirectory     = "/${trim(var.destination_prefix, "/")}/"
  s3_storage_class = "STANDARD"

  s3_config {
    bucket_access_role_arn = var.role_arn
  }

  tags = {
    Name = "${var.name_prefix}-landing-files"
  }
}

resource "aws_datasync_task" "this" {
  name                     = "${var.name_prefix}-files-to-landing"
  source_location_arn      = aws_datasync_location_s3.source.arn
  destination_location_arn = aws_datasync_location_s3.landing.arn
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.this.arn

  # S3 to S3: no POSIX metadata to carry
  options {
    transfer_mode          = "CHANGED"
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS"
    preserve_deleted_files = "PRESERVE"
    posix_permissions      = "NONE"
    uid                    = "NONE"
    gid                    = "NONE"
    log_level              = "TRANSFER"
  }

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}
