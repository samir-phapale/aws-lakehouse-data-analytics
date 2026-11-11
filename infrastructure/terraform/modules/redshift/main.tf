resource "aws_iam_role" "redshift" {
  name = "${var.name_prefix}-redshift-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = ["redshift.amazonaws.com", "redshift-serverless.amazonaws.com"] }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-redshift-role"
  }
}

data "aws_iam_policy_document" "redshift" {
  statement {
    sid       = "CuratedList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.curated_bucket_name}"]
  }

  statement {
    sid       = "CuratedRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.curated_bucket_name}/*"]
  }

  statement {
    sid       = "KmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid    = "CatalogRead"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = [
      "arn:aws:glue:${var.region}:${var.account_id}:catalog",
      "arn:aws:glue:${var.region}:${var.account_id}:database/${var.spectrum_database}",
      "arn:aws:glue:${var.region}:${var.account_id}:table/${var.spectrum_database}/*",
    ]
  }

  # Lake Formation vends data access for catalog tables; no resource-level scoping
  statement {
    sid       = "LakeFormationDataAccess"
    effect    = "Allow"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "redshift" {
  name   = "${var.name_prefix}-redshift-policy"
  role   = aws_iam_role.redshift.id
  policy = data.aws_iam_policy_document.redshift.json
}

resource "aws_security_group" "redshift" {
  name        = "${var.name_prefix}-redshift-sg"
  description = "Redshift Serverless workgroup; no inbound (clients use the Data API)"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-redshift-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "redshift_all" {
  security_group_id = aws_security_group.redshift.id
  description       = "Spectrum and S3 traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_redshiftserverless_namespace" "this" {
  namespace_name        = "${var.name_prefix}-warehouse"
  db_name               = "lakehouse"
  admin_username        = "lakehouse_admin"
  manage_admin_password = true
  kms_key_id            = var.kms_key_arn
  iam_roles             = [aws_iam_role.redshift.arn]
  default_iam_role_arn  = aws_iam_role.redshift.arn
  log_exports           = ["userlog", "connectionlog", "useractivitylog"]

  depends_on = [aws_iam_role_policy.redshift]
}

resource "aws_redshiftserverless_workgroup" "this" {
  namespace_name      = aws_redshiftserverless_namespace.this.namespace_name
  workgroup_name      = "${var.name_prefix}-warehouse"
  base_capacity       = var.base_capacity
  max_capacity        = 16
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.redshift.id]
  publicly_accessible = false
}
