variable "name_prefix" {
  description = "Prefix for rule, role and topic names (lakehouse-dev)"
  type        = string
}

variable "bucket_prefix" {
  description = "Prefix of the lakehouse bucket names (sam-lakehouse)"
  type        = string
}

variable "project_tag" {
  description = "Value of the Project tag the Config rules are scoped to"
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

variable "kms_key_arn" {
  description = "KMS key for the SNS topic"
  type        = string
}

variable "alert_email" {
  description = "Email subscribed to the alerts topic; empty for none"
  type        = string
}
