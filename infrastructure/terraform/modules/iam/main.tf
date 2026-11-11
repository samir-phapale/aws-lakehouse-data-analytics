locals {
  source_files_prefix  = trim(var.source_files_prefix, "/")
  landing_files_prefix = trim(var.landing_files_prefix, "/")
  mysql_load_prefix    = trim(var.source_mysql_load_prefix, "/")
  stream_replay_prefix = trim(var.source_stream_replay_prefix, "/")

  # MSK topic and group ARNs share the cluster ARN's <name>/<uuid> suffix
  msk_topic_arn = "${replace(var.msk_cluster_arn, ":cluster/", ":topic/")}/${var.kafka_topic}"
  msk_group_arn = "${replace(var.msk_cluster_arn, ":cluster/", ":group/")}/*"

  lakehouse_zone_buckets = merge(
    var.enable_transformed_zone ? { transformed = var.transformed_bucket_arn } : {},
    var.enable_curated_zone ? { curated = var.curated_bucket_arn } : {},
  )
}

# One Glue role per simulated account: ingest (landing zone), lakehouse (lake house) and
# crawler (data governance)

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

data "aws_iam_policy_document" "glue_common" {
  statement {
    sid       = "GlueAssetsList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.glue_assets_bucket_arn]
  }

  statement {
    sid       = "GlueScriptsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.glue_assets_bucket_arn}/scripts/*"]
  }

  # Glue's S3 filesystem writes an empty "<folder>_$folder$" marker next to each top folder
  statement {
    sid     = "GlueTempReadWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.glue_assets_bucket_arn}/temp/*",
      "${var.glue_assets_bucket_arn}/temp_$folder$",
    ]
  }

  # Job.init reads the job's security configuration; this action has no resource-level scoping
  statement {
    sid       = "GlueSecurityConfigurationRead"
    effect    = "Allow"
    actions   = ["glue:GetSecurityConfiguration"]
    resources = ["*"]
  }

  statement {
    sid    = "KmsUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }

  statement {
    sid    = "GlueLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:AssociateKmsKey",
    ]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws-glue/*"]
  }
}

resource "aws_iam_role" "glue_ingest" {
  name               = "${var.name_prefix}-glue-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name = "${var.name_prefix}-glue-ingest-role"
  }
}

data "aws_iam_policy_document" "glue_ingest" {
  source_policy_documents = [data.aws_iam_policy_document.glue_common.json]

  statement {
    sid       = "LandingList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.landing_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["rds", "rds/*", "stream", "stream/*"]
    }
  }

  # Delete: a same-day rerun replaces that day's MySQL extract
  statement {
    sid     = "LandingWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.landing_bucket_arn}/rds/*",
      "${var.landing_bucket_arn}/stream/*",
      "${var.landing_bucket_arn}/rds_$folder$",
      "${var.landing_bucket_arn}/stream_$folder$",
    ]
  }

  statement {
    sid       = "SourceMysqlLoadList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.source_files_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [local.mysql_load_prefix, "${local.mysql_load_prefix}/*"]
    }
  }

  statement {
    sid       = "SourceMysqlLoadRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.source_files_bucket_arn}/${local.mysql_load_prefix}/*"]
  }

  statement {
    sid     = "GlueCheckpointsReadWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.glue_assets_bucket_arn}/checkpoints/*",
      "${var.glue_assets_bucket_arn}/checkpoints_$folder$",
    ]
  }

  statement {
    sid       = "MskConnect"
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid       = "MskTopicRead"
    effect    = "Allow"
    actions   = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
    resources = [local.msk_topic_arn]
  }

  statement {
    sid       = "MskConsumerGroups"
    effect    = "Allow"
    actions   = ["kafka-cluster:DescribeGroup", "kafka-cluster:AlterGroup"]
    resources = [local.msk_group_arn]
  }

  statement {
    sid       = "MskBootstrapLookup"
    effect    = "Allow"
    actions   = ["kafka:DescribeCluster", "kafka:DescribeClusterV2", "kafka:GetBootstrapBrokers"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid       = "RdsSecretRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.rds_secret_arn]
  }

  statement {
    sid     = "GlueConnectionRead"
    effect  = "Allow"
    actions = ["glue:GetConnection", "glue:GetConnections"]
    resources = [
      "arn:aws:glue:${var.region}:${var.account_id}:catalog",
      "arn:aws:glue:${var.region}:${var.account_id}:connection/${var.name_prefix}-*",
    ]
  }

  # Glue attaches ENIs to reach RDS and MSK; these EC2 calls have no resource-level scoping
  statement {
    sid    = "GlueVpcNetworking"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeVpcEndpoints",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcAttribute",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "GlueEniTags"
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:network-interface/*"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["aws-glue-service-resource"]
    }
  }
}

resource "aws_iam_role_policy" "glue_ingest" {
  name   = "${var.name_prefix}-glue-ingest-policy"
  role   = aws_iam_role.glue_ingest.id
  policy = data.aws_iam_policy_document.glue_ingest.json
}

resource "aws_iam_role" "glue_lakehouse" {
  name               = "${var.name_prefix}-glue-lakehouse-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name = "${var.name_prefix}-glue-lakehouse-role"
  }
}

data "aws_iam_policy_document" "glue_lakehouse" {
  source_policy_documents = [data.aws_iam_policy_document.glue_common.json]

  statement {
    sid       = "LandingList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.landing_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "rds", "rds/*", "stream", "stream/*",
        local.landing_files_prefix, "${local.landing_files_prefix}/*",
      ]
    }
  }

  statement {
    sid     = "LandingRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${var.landing_bucket_arn}/rds/*",
      "${var.landing_bucket_arn}/stream/*",
      "${var.landing_bucket_arn}/${local.landing_files_prefix}/*",
    ]
  }

  statement {
    sid       = "RawList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.raw_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["rds", "rds/*", "files", "files/*", "stream", "stream/*"]
    }
  }

  # Delete is needed for Delta overwrites and VACUUM
  statement {
    sid     = "RawDeltaWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.raw_bucket_arn}/rds/*",
      "${var.raw_bucket_arn}/files/*",
      "${var.raw_bucket_arn}/stream/*",
      "${var.raw_bucket_arn}/rds_$folder$",
      "${var.raw_bucket_arn}/files_$folder$",
      "${var.raw_bucket_arn}/stream_$folder$",
    ]
  }
}

resource "aws_iam_role_policy" "glue_lakehouse" {
  name   = "${var.name_prefix}-glue-lakehouse-policy"
  role   = aws_iam_role.glue_lakehouse.id
  policy = data.aws_iam_policy_document.glue_lakehouse.json
}

# The lakehouse role owns the whole transformed and curated buckets once each zone is enabled
data "aws_iam_policy_document" "glue_lakehouse_zone" {
  for_each = local.lakehouse_zone_buckets

  statement {
    sid       = "${title(each.key)}List"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [each.value]
  }

  statement {
    sid       = "${title(each.key)}ReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${each.value}/*"]
  }
}

resource "aws_iam_role_policy" "glue_lakehouse_zone" {
  for_each = local.lakehouse_zone_buckets

  name   = "${var.name_prefix}-glue-lakehouse-${each.key}-policy"
  role   = aws_iam_role.glue_lakehouse.id
  policy = data.aws_iam_policy_document.glue_lakehouse_zone[each.key].json
}

resource "aws_iam_role" "glue_crawler" {
  name               = "${var.name_prefix}-glue-crawler-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name = "${var.name_prefix}-glue-crawler-role"
  }
}

data "aws_iam_policy_document" "glue_crawler" {
  statement {
    sid       = "ZoneList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.raw_bucket_arn, var.transformed_bucket_arn, var.curated_bucket_arn]
  }

  statement {
    sid     = "ZoneRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${var.raw_bucket_arn}/*",
      "${var.transformed_bucket_arn}/*",
      "${var.curated_bucket_arn}/*",
    ]
  }

  # The Spectrum crawler writes symlink manifests into each curated Delta table (Spectrum cannot read Delta)
  statement {
    sid     = "CuratedManifestWrite"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.curated_bucket_arn}/*/_symlink_format_manifest/*",
      "${var.curated_bucket_arn}/*/_symlink_format_manifest_$folder$",
    ]
  }

  statement {
    sid    = "CatalogWrite"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:UpdatePartition",
      "glue:BatchUpdatePartition",
    ]
    resources = [
      "arn:aws:glue:${var.region}:${var.account_id}:catalog",
      "arn:aws:glue:${var.region}:${var.account_id}:database/${var.catalog_database_prefix}_*",
      "arn:aws:glue:${var.region}:${var.account_id}:table/${var.catalog_database_prefix}_*/*",
    ]
  }

  # Same unscoped action as in glue_common
  statement {
    sid       = "GlueSecurityConfigurationRead"
    effect    = "Allow"
    actions   = ["glue:GetSecurityConfiguration"]
    resources = ["*"]
  }

  statement {
    sid       = "KmsUse"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey*", "kms:Encrypt"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid    = "CrawlerLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:AssociateKmsKey",
    ]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws-glue/*"]
  }
}

resource "aws_iam_role_policy" "glue_crawler" {
  name   = "${var.name_prefix}-glue-crawler-policy"
  role   = aws_iam_role.glue_crawler.id
  policy = data.aws_iam_policy_document.glue_crawler.json
}

data "aws_iam_policy_document" "datasync_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

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
      values   = ["arn:aws:datasync:${var.region}:${var.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "datasync" {
  name               = "${var.name_prefix}-datasync-role"
  assume_role_policy = data.aws_iam_policy_document.datasync_assume_role.json

  tags = {
    Name = "${var.name_prefix}-datasync-role"
  }
}

# Actions follow the documented DataSync S3 location role requirements
data "aws_iam_policy_document" "datasync" {
  statement {
    sid    = "BucketLevel"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [var.source_files_bucket_arn, var.landing_bucket_arn]
  }

  statement {
    sid    = "SourceRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetObjectVersionTagging",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${var.source_files_bucket_arn}/${local.source_files_prefix}/*"]
  }

  statement {
    sid    = "LandingWrite"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetObjectVersionTagging",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = ["${var.landing_bucket_arn}/${local.landing_files_prefix}/*"]
  }

  statement {
    sid    = "KmsUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "datasync" {
  name   = "${var.name_prefix}-datasync-policy"
  role   = aws_iam_role.datasync.id
  policy = data.aws_iam_policy_document.datasync.json
}

data "aws_iam_policy_document" "producer_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "producer" {
  name               = "${var.name_prefix}-kafka-producer-role"
  assume_role_policy = data.aws_iam_policy_document.producer_assume_role.json

  tags = {
    Name = "${var.name_prefix}-kafka-producer-role"
  }
}

# Reached through SSM Run Command instead of SSH
resource "aws_iam_role_policy_attachment" "producer_ssm" {
  role       = aws_iam_role.producer.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "MskConnect"
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid    = "MskTopicWrite"
    effect = "Allow"
    actions = [
      "kafka-cluster:CreateTopic",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:WriteData",
    ]
    resources = [local.msk_topic_arn]
  }

  statement {
    sid       = "ProducerCodeRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.glue_assets_bucket_arn}/producer/*"]
  }

  statement {
    sid       = "ReplayDataRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.source_files_bucket_arn}/${local.stream_replay_prefix}/*"]
  }

  statement {
    sid       = "KmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "producer" {
  name   = "${var.name_prefix}-kafka-producer-policy"
  role   = aws_iam_role.producer.id
  policy = data.aws_iam_policy_document.producer.json
}

resource "aws_iam_instance_profile" "producer" {
  name = "${var.name_prefix}-kafka-producer-profile"
  role = aws_iam_role.producer.name
}
