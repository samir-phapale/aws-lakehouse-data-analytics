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

variable "kms_key_arn" {
  description = "Lakehouse KMS key the roles may use"
  type        = string
}

variable "landing_bucket_arn" {
  description = "ARN of the landing bucket"
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN of the raw bucket"
  type        = string
}

variable "transformed_bucket_arn" {
  description = "ARN of the transformed bucket"
  type        = string
}

variable "curated_bucket_arn" {
  description = "ARN of the curated bucket"
  type        = string
}

variable "glue_assets_bucket_arn" {
  description = "ARN of the bucket holding Glue scripts and temp files"
  type        = string
}

variable "source_files_bucket_arn" {
  description = "ARN of the source-files bucket"
  type        = string
}

variable "enable_transformed_zone" {
  description = "Give the lakehouse role access to the transformed bucket"
  type        = bool
}

variable "enable_curated_zone" {
  description = "Give the lakehouse role access to the curated bucket"
  type        = bool
}

variable "catalog_database_prefix" {
  description = "Prefix of the Glue databases the crawler role may write (<prefix>_raw, ...)"
  type        = string
}

variable "rds_secret_arn" {
  description = "Secrets Manager secret with the RDS credentials"
  type        = string
}

variable "source_files_prefix" {
  description = "Prefix DataSync reads in the source-files bucket"
  type        = string
}

variable "source_mysql_load_prefix" {
  description = "Prefix in the source-files bucket holding the CSVs the Glue loader writes into MySQL"
  type        = string
}

variable "source_stream_replay_prefix" {
  description = "Prefix in the source-files bucket holding the file the producer replays"
  type        = string
}

variable "landing_files_prefix" {
  description = "Prefix in the landing bucket where DataSync delivers files"
  type        = string
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster the producer writes to and Glue reads from"
  type        = string
}

variable "kafka_topic" {
  description = "Kafka topic for the streaming source"
  type        = string
}
