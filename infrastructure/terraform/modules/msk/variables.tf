variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the brokers; one broker is placed in each"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the brokers"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for data at rest and the broker log group"
  type        = string
}

variable "kafka_version" {
  description = "Apache Kafka version"
  type        = string
}

variable "broker_instance_type" {
  description = "MSK broker instance type"
  type        = string
}

variable "broker_volume_size" {
  description = "EBS storage per broker, in GiB"
  type        = number
}
