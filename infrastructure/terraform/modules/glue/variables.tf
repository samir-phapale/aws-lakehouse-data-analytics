variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "glue_version" {
  description = "AWS Glue version"
  type        = string
}

variable "lakehouse_role_arn" {
  description = "Glue lakehouse role (landing -> raw -> transformed -> curated)"
  type        = string
}

variable "ingest_role_arn" {
  description = "Glue ingest role (MySQL loader, MySQL -> landing, MSK -> landing)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the Glue security configuration"
  type        = string
}

variable "glue_assets_bucket_name" {
  description = "Bucket for scripts, temp files and streaming checkpoints"
  type        = string
}

variable "landing_bucket_name" {
  description = "Landing bucket: the ingest jobs write it, the landing -> raw job reads it"
  type        = string
}

variable "transformed_bucket_name" {
  description = "Transformed bucket the raw -> transformed job writes"
  type        = string
}

variable "raw_bucket_name" {
  description = "Raw bucket the landing -> raw job writes"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet where Glue places its ENIs"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone of subnet_id"
  type        = string
}

variable "security_group_id" {
  description = "Security group for the Glue ENIs"
  type        = string
}

variable "mysql_address" {
  description = "RDS MySQL hostname"
  type        = string
}

variable "mysql_port" {
  description = "RDS MySQL port"
  type        = number
}

variable "mysql_db_name" {
  description = "Source database name"
  type        = string
}

variable "mysql_secret_arn" {
  description = "Secrets Manager secret with the MySQL credentials"
  type        = string
}

variable "mysql_source_tables" {
  description = "MySQL tables to load and export"
  type        = list(string)
}

variable "source_files_bucket_name" {
  description = "Source-files bucket the MySQL loader job reads"
  type        = string
}

variable "mysql_load_prefix" {
  description = "Prefix in the source-files bucket with one <table>.csv per MySQL table"
  type        = string
}

variable "file_datasets" {
  description = "File data sets; each is a sub-folder of the landing prefix"
  type        = list(string)
}

variable "file_landing_prefix" {
  description = "Landing prefix where DataSync delivers the files (one sub-folder per data set)"
  type        = string
}

variable "file_delta_prefix" {
  description = "Raw prefix holding one Delta table per file data set"
  type        = string
}

variable "file_source_format" {
  description = "Format of the staged files: csv, json or parquet"
  type        = string
}

variable "file_csv_delimiter" {
  description = "Column delimiter for csv files"
  type        = string
}

variable "file_csv_header" {
  description = "Whether csv files have a header row"
  type        = bool
}

variable "enable_curated_zone" {
  description = "Deploy the transformed -> curated job and its code"
  type        = bool
}

variable "curated_bucket_name" {
  description = "Curated zone bucket"
  type        = string
}

variable "enable_transformed_zone" {
  description = "Deploy the raw -> transformed job and its code"
  type        = bool
}

variable "transformations_dir" {
  description = "Local folder with the transformation code (src/transformations)"
  type        = string
}

variable "scripts_dir" {
  description = "Local src/ingestion folder; script paths below it are per source"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK bootstrap brokers for SASL/IAM (port 9098)"
  type        = string
}

variable "kafka_topic" {
  description = "Kafka topic the streaming job reads"
  type        = string
}
