variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "account_id" {
  description = "AWS account ID that owns the key"
  type        = string
}

variable "region" {
  description = "AWS region, used to name the CloudWatch Logs service principal"
  type        = string
}
