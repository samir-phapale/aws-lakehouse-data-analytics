variable "name_prefix" {
  description = "Prefix for Redshift resource names"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC for the workgroup"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets in at least three AZs (Redshift Serverless requirement)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 3
    error_message = "Redshift Serverless needs subnets in at least three availability zones."
  }
}

variable "kms_key_arn" {
  description = "KMS key for the namespace and for reading the curated bucket"
  type        = string
}

variable "curated_bucket_name" {
  description = "Curated zone bucket Spectrum reads"
  type        = string
}

variable "spectrum_database" {
  description = "Glue database with the symlink-manifest curated tables"
  type        = string
}

variable "base_capacity" {
  description = "Base RPUs (8 is the minimum)"
  type        = number
}
