variable "aws_region" {
  description = "AWS region for the pipeline and the lakehouse it deploys"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, first part of every resource name"
  type        = string
  default     = "lakehouse"
}

variable "environment" {
  description = "Environment the pipeline deploys (main root var file environments/<env>/terraform.tfvars)"
  type        = string
  default     = "dev"
}

variable "bucket_owner_prefix" {
  description = "Prefix that makes bucket names unique (sam -> sam-lakehouse-pipeline-artifacts-<account>)"
  type        = string
  default     = "sam"
}

variable "github_repository" {
  description = "GitHub repository the pipeline builds, as owner/name"
  type        = string
}

variable "branch_name" {
  description = "Branch whose pushes start the pipeline"
  type        = string
  default     = "main"
}

variable "deployer_admin_role_arn" {
  description = "Human admin role (SSO) kept in the artifacts bucket allow-list so it can inspect plans and is never locked out"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket holding the main root's Terraform state"
  type        = string
}

variable "tf_state_key" {
  description = "State key of the main root (environments/<env>/backend.hcl)"
  type        = string
  default     = "lakehouse/dev/terraform.tfstate"
}

variable "log_retention_days" {
  description = "Retention of the CodeBuild log group"
  type        = number
  default     = 14
}
