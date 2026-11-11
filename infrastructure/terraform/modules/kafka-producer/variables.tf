variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (arm64, Graviton)"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the instance"
  type        = string
}

variable "security_group_id" {
  description = "Security group for the instance"
  type        = string
}

variable "instance_profile_name" {
  description = "Instance profile carrying the producer IAM role"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the root volume"
  type        = string
}
