# GitHub -> CodePipeline (plan + OPA, manual approval, apply) for the main root.
# Bootstrapped once by hand; the pipeline then runs on every push to the branch.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  validate_plan_project = "${local.name_prefix}-validate-plan"
  pipeline_name         = "${local.name_prefix}-pipeline"

  tf_env = {
    TF_STATE_BUCKET = var.tf_state_bucket
    TF_STATE_KEY    = var.tf_state_key
    TF_STATE_REGION = local.region
    TF_VAR_FILE     = "environments/${var.environment}/terraform.tfvars"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = toset(["codebuild", "codepipeline"])

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["${each.key}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

module "kms" {
  source = "../../infrastructure/terraform/modules/kms"

  name_prefix = "${local.name_prefix}-cicd"
  account_id  = local.account_id
  region      = local.region
}

module "artifacts_bucket" {
  source = "../../infrastructure/terraform/modules/s3"

  bucket_name = "${var.bucket_owner_prefix}-${var.project_name}-pipeline-artifacts-${local.account_id}"
  kms_key_arn = module.kms.key_arn
  allowed_principal_arns = [
    aws_iam_role.pipeline.arn,
    aws_iam_role.codebuild.arn,
    var.deployer_admin_role_arn,
  ]
}

# Created PENDING: authorize it once in the console (Developer Tools -> Connections) before the
# first pipeline run
resource "aws_codeconnections_connection" "github" {
  name          = "${local.name_prefix}-github"
  provider_type = "GitHub"
}

# Deliberate least-privilege exception: it applies the whole main root (IAM, VPC, RDS, MSK, ...).
# Only CodeBuild in this account can assume it, and apply waits for approval of an OPA-checked plan.
# The main root puts this exact ARN in its bucket allow-lists, so keep the name and path.
resource "aws_iam_role" "codebuild" {
  name               = "${local.name_prefix}-cicd-deploy"
  description        = "CodeBuild role that plans and applies the lakehouse Terraform"
  assume_role_policy = data.aws_iam_policy_document.trust["codebuild"].json
}

resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  role       = aws_iam_role.codebuild.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${local.name_prefix}-cicd"
  retention_in_days = var.log_retention_days
  kms_key_id        = module.kms.key_arn
}

resource "aws_codebuild_project" "validate_plan" {
  name           = local.validate_plan_project
  description    = "fmt, validate, unit tests, terraform plan and OPA (conftest) checks of the plan"
  service_role   = aws_iam_role.codebuild.arn
  encryption_key = module.kms.key_arn
  build_timeout  = 60

  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspecs/plan.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    # PySpark unit tests need more memory than SMALL gives
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = local.tf_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "validate-plan"
    }
  }
}

resource "aws_codebuild_project" "apply" {
  name           = "${local.name_prefix}-apply"
  description    = "terraform apply of the approved plan"
  service_role   = aws_iam_role.codebuild.arn
  encryption_key = module.kms.key_arn
  build_timeout  = 120

  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspecs/apply.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = local.tf_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "apply"
    }
  }
}

# Not a pipeline stage: started by hand at the end; destroy.yml refuses to run unless the build
# overrides CONFIRM_DESTROY with EXPECTED_CONFIRM
resource "aws_codebuild_project" "destroy" {
  name           = "${local.name_prefix}-destroy"
  description    = "terraform destroy of the main root (manual, needs CONFIRM_DESTROY)"
  service_role   = aws_iam_role.codebuild.arn
  encryption_key = module.kms.key_arn
  build_timeout  = 120

  source {
    type      = "GITHUB"
    location  = "https://github.com/${var.github_repository}.git"
    buildspec = "cicd/buildspecs/destroy.yml"

    auth {
      type     = "CODECONNECTIONS"
      resource = aws_codeconnections_connection.github.arn
    }
  }

  source_version = "refs/heads/${var.branch_name}"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = merge(local.tf_env, { EXPECTED_CONFIRM = local.name_prefix })
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "destroy"
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${local.name_prefix}-cicd-pipeline"
  description        = "CodePipeline role for ${local.pipeline_name}"
  assume_role_policy = data.aws_iam_policy_document.trust["codepipeline"].json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "SourceFromGitHub"
    actions   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
    resources = [aws_codeconnections_connection.github.arn]
  }

  statement {
    sid       = "RunBuilds"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.validate_plan.arn, aws_codebuild_project.apply.arn]
  }

  statement {
    sid       = "ArtifactsBucket"
    actions   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
    resources = [module.artifacts_bucket.bucket_arn]
  }

  statement {
    sid       = "ArtifactsObjects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    resources = ["${module.artifacts_bucket.bucket_arn}/*"]
  }

  statement {
    sid       = "ArtifactsKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [module.kms.key_arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "${local.name_prefix}-cicd-pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_codepipeline" "this" {
  name           = local.pipeline_name
  pipeline_type  = "V2"
  execution_mode = "SUPERSEDED"
  role_arn       = aws_iam_role.pipeline.arn

  artifact_store {
    type     = "S3"
    location = module.artifacts_bucket.bucket_name

    encryption_key {
      type = "KMS"
      id   = module.kms.key_arn
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = aws_codeconnections_connection.github.arn
        FullRepositoryId     = var.github_repository
        BranchName           = var.branch_name
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "ValidateAndPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.validate_plan.name
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "ReviewPlan"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Review the terraform plan in the ${local.validate_plan_project} build log, then approve to apply it."
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.apply.name
      }
    }
  }

  depends_on = [aws_iam_role_policy.pipeline]
}
