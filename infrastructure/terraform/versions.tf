terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Cloud Control provider, only for services hashicorp/aws lacks (DataBrew)
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    # Waits for IAM propagation where a service checks a new role at create time (DataBrew)
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  # Added by the account's tagging automation and Cloud Custodian; not ours to remove
  ignore_tags {
    keys         = ["CreatedBy", "CreatedDate", "PrincipalId"]
    key_prefixes = ["custodian_"]
  }
}

provider "awscc" {
  region = var.aws_region
}
