terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same bucket as the main root, key lakehouse/cicd/terraform.tfstate (backend.hcl)
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

  # Added to new resources by the account's tagging automation; not ours to remove
  ignore_tags {
    keys = ["CreatedBy", "CreatedDate", "PrincipalId"]
  }
}
