variable "name_prefix" {
  description = "Prefix for DataBrew resource names"
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

variable "transformed_bucket_name" {
  description = "Transformed zone bucket (snapshots in _dq/, reports in _dq_reports/)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the profile and validation reports"
  type        = string
}
