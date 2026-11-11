output "load_mysql_job_name" {
  description = "Glue job that loads the Olist CSVs into MySQL"
  value       = aws_glue_job.load_mysql.name
}

output "ingest_job_name" {
  description = "Glue job that exports the MySQL tables to landing"
  value       = aws_glue_job.ingest.name
}

output "raw_to_transformed_job_name" {
  description = "Glue job that builds the transformed zone"
  value       = one(aws_glue_job.raw_to_transformed[*].name)
}

output "landing_to_raw_job_name" {
  description = "Glue job that promotes every landing source to raw Delta tables"
  value       = aws_glue_job.landing_to_raw.name
}

output "stream_job_name" {
  description = "Glue streaming job that writes the MSK topic to landing"
  value       = aws_glue_job.stream.name
}

output "transformed_to_curated_job_name" {
  description = "Glue job that builds the curated zone"
  value       = one(aws_glue_job.transformed_to_curated[*].name)
}

output "security_configuration_name" {
  description = "Glue security configuration (KMS)"
  value       = aws_glue_security_configuration.this.name
}
