variable "name_prefix" {
  description = "Prefix for resource names"
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

variable "role_arn" {
  description = "Role DataSync assumes for both S3 locations"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the task log group"
  type        = string
}

variable "source_bucket_arn" {
  description = "Bucket DataSync reads from"
  type        = string
}

variable "source_prefix" {
  description = "Prefix to copy from in the source bucket"
  type        = string
}

variable "destination_bucket_arn" {
  description = "Landing bucket DataSync writes to"
  type        = string
}

variable "destination_prefix" {
  description = "Prefix to write to in the landing bucket"
  type        = string
}
