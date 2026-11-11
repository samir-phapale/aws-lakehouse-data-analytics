variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets (two AZs) for the DB subnet group"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to the instance"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for storage and the master-user secret"
  type        = string
}

variable "engine_version" {
  description = "MySQL engine version"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "master_username" {
  description = "Master user name"
  type        = string
}
