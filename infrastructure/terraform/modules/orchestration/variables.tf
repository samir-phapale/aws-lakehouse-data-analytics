variable "name_prefix" {
  description = "Prefix for names (lakehouse-dev)"
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
  description = "KMS key for log groups and the alerts topic"
  type        = string
}

variable "asl_path" {
  description = "Step Functions definition template"
  type        = string
}

variable "lambda_dir" {
  description = "Folder with the Lambda sources (dq_gate/handler.py)"
  type        = string
}

variable "sql_dir" {
  description = "Folder with the Redshift SQL (01_external_schema.sql, 02_load_marts.sql)"
  type        = string
}

variable "ingest_job_name" {
  description = "Glue job MySQL -> landing"
  type        = string
}

variable "datasync_task_arn" {
  description = "DataSync task source files -> landing"
  type        = string
}

variable "landing_to_raw_job_name" {
  description = "Glue job landing -> raw"
  type        = string
}

variable "raw_to_transformed_job_name" {
  description = "Glue job raw -> transformed"
  type        = string
}

variable "transformed_to_curated_job_name" {
  description = "Glue job transformed -> curated"
  type        = string
}

variable "databrew_jobs" {
  description = "Transformed table -> DataBrew profile job name"
  type        = map(string)
}

variable "databrew_job_arns" {
  description = "ARNs of the DataBrew profile jobs"
  type        = list(string)
}

variable "crawler_names" {
  description = "Glue crawlers to run after curated is built"
  type        = list(string)
}

variable "transformed_bucket_name" {
  description = "Transformed bucket (DataBrew reports in _dq_reports/)"
  type        = string
}

variable "redshift_workgroup_name" {
  description = "Redshift Serverless workgroup"
  type        = string
}

variable "redshift_workgroup_arn" {
  description = "Redshift Serverless workgroup ARN"
  type        = string
}

variable "redshift_database" {
  description = "Redshift database"
  type        = string
}

variable "redshift_secret_arn" {
  description = "Secret with the Redshift admin credentials"
  type        = string
}

variable "redshift_role_arn" {
  description = "IAM role for the Spectrum external schema"
  type        = string
}

variable "spectrum_database" {
  description = "Glue database with the Spectrum (manifest) tables"
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for success and failure notices"
  type        = string
}

variable "enable_schedule" {
  description = "Run the pipeline daily at 03:00 UTC"
  type        = bool
}
