variable "name_prefix" {
  description = "Prefix for crawler and workgroup names"
  type        = string
}

variable "database_prefix" {
  description = "Prefix for the Glue databases (<prefix>_raw, ...); underscores only"
  type        = string
}

variable "crawler_role_arn" {
  description = "IAM role the crawlers run as"
  type        = string
}

variable "security_configuration_name" {
  description = "Glue security configuration (KMS for crawler logs)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for Athena query results"
  type        = string
}

variable "raw_bucket_name" {
  description = "Raw zone bucket"
  type        = string
}

variable "transformed_bucket_name" {
  description = "Transformed zone bucket"
  type        = string
}

variable "curated_bucket_name" {
  description = "Curated zone bucket"
  type        = string
}

variable "results_bucket_name" {
  description = "Bucket for Athena query results (athena-results/ prefix)"
  type        = string
}

variable "raw_table_paths" {
  description = "Raw Delta table folders, relative to the raw bucket (e.g. rds/salesdb/orders)"
  type        = list(string)
}

variable "transformed_tables" {
  description = "Transformed Delta table folders (top level of the transformed bucket)"
  type        = list(string)
}

variable "curated_tables" {
  description = "Curated Delta table folders (top level of the curated bucket)"
  type        = list(string)
}

variable "enable_transformed_zone" {
  description = "Create the transformed crawler"
  type        = bool
}

variable "enable_curated_zone" {
  description = "Create the curated and Spectrum crawlers and the saved Athena queries"
  type        = bool
}

variable "sql_dir" {
  description = "Folder with the saved Athena queries (*.sql)"
  type        = string
}

variable "analyst_principal_arns" {
  description = "IAM roles granted SELECT on every catalog table through Lake Formation"
  type        = list(string)
}

variable "spectrum_role_arn" {
  description = "Redshift role granted SELECT on the Spectrum manifest tables"
  type        = string
}
