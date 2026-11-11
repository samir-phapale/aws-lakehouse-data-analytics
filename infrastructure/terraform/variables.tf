variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "lakehouse"
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "bucket_owner_prefix" {
  description = "Extra prefix for bucket names only (S3 names are global): <prefix>-<project>-<zone>-<account>"
  type        = string
  default     = "sam"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,14}$", var.bucket_owner_prefix))
    error_message = "bucket_owner_prefix must be 1-15 lower-case letters, digits or hyphens."
  }
}

variable "enable_transformed_zone" {
  description = "Deploy the raw -> transformed Glue job, its code and IAM"
  type        = bool
  default     = false
}

variable "enable_curated_zone" {
  description = "Deploy the transformed -> curated Glue job, its IAM, the curated crawlers and saved Athena queries (needs enable_transformed_zone)"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_curated_zone || var.enable_transformed_zone
    error_message = "enable_curated_zone needs enable_transformed_zone = true."
  }
}

variable "admin_principal_arns" {
  description = "Admin/analyst roles: allowed into the lake buckets and granted SELECT on every catalog table"
  type        = list(string)
  default     = []
}

variable "deployer_principal_arns" {
  description = "Roles that run Terraform (the CI/CD CodeBuild role): allowed into the lake buckets"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Email subscribed to the alerts topic; empty for none"
  type        = string
  default     = ""
}

variable "enable_pipeline_schedule" {
  description = "Run the Step Functions pipeline daily (03:00 UTC)"
  type        = bool
  default     = false
}

variable "redshift_base_capacity" {
  description = "Redshift Serverless base RPUs (minimum 8)"
  type        = number
  default     = 8
}

# Network

variable "vpc_cidr" {
  description = "CIDR block for the lakehouse VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ: RDS needs two AZs, Redshift Serverless three (MSK uses the first two)"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]
}

variable "interface_endpoint_services" {
  description = "AWS services reached through interface VPC endpoints; ssm, ssmmessages and ec2messages serve SSM Run Command on the producer"
  type        = list(string)
  default     = ["glue", "secretsmanager", "kms", "logs", "ssm", "ssmmessages", "ec2messages"]
}

# RDS MySQL source

variable "mysql_engine_version" {
  description = "RDS MySQL engine version"
  type        = string
  default     = "8.0"
}

variable "mysql_instance_class" {
  description = "RDS instance class for the source database"
  type        = string
  default     = "db.t4g.micro"
}

variable "mysql_db_name" {
  description = "Initial database created on the RDS instance"
  type        = string
  default     = "salesdb"
}

variable "mysql_master_username" {
  description = "RDS master user name; the password is generated and kept in Secrets Manager by RDS"
  type        = string
  default     = "lakehouse_admin"
}

variable "mysql_source_tables" {
  description = "Olist tables the loader job creates in MySQL and the ingest job copies to raw"
  type        = list(string)
  default = [
    "customers", "orders", "order_items", "order_payments", "products", "sellers",
    "order_reviews", "geolocation", "category_translation",
  ]
}

# Glue

variable "glue_version" {
  description = "AWS Glue version for the jobs"
  type        = string
  default     = "4.0"
}

# S3 file source (DataSync)

variable "source_files_prefix" {
  description = "Prefix in the source-files bucket that DataSync copies; each data set is a sub-folder"
  type        = string
  default     = "files/"
}

variable "file_datasets" {
  description = "Sub-folders of source_files_prefix; each becomes the raw Delta table files/<name>/"
  type        = list(string)
  default     = ["tpch_customer"]
}

variable "file_source_format" {
  description = "Format of the uploaded source files: csv, json or parquet"
  type        = string
  default     = "csv"

  validation {
    condition     = contains(["csv", "json", "parquet"], var.file_source_format)
    error_message = "file_source_format must be csv, json or parquet."
  }
}

variable "file_csv_delimiter" {
  description = "Column delimiter when file_source_format is csv (TPC-H dbgen .tbl files use |)"
  type        = string
  default     = "|"
}

variable "file_csv_header" {
  description = "Whether csv files have a header row (TPC-H .tbl files do not)"
  type        = bool
  default     = false
}

# MSK streaming source

variable "kafka_version" {
  description = "Apache Kafka version for MSK"
  type        = string
  default     = "3.8.x"
}

variable "msk_broker_instance_type" {
  description = "MSK broker instance type (two brokers, one per private subnet)"
  type        = string
  default     = "kafka.t3.small"
}

variable "msk_broker_volume_size" {
  description = "EBS storage per MSK broker, in GiB"
  type        = number
  default     = 10
}

variable "kafka_topic" {
  description = "Topic the producer writes and the Glue streaming job lands at raw/stream/<topic>/"
  type        = string
  default     = "order_events"
}

variable "producer_instance_type" {
  description = "EC2 instance type for the Kafka producer (arm64)"
  type        = string
  default     = "t4g.micro"
}
