output "landing_bucket_name" {
  description = "Landing zone: every source as delivered (rds/, files/, stream/)"
  value       = module.bucket["landing"].bucket_name
}

output "raw_bucket_name" {
  description = "Raw zone: every source as Delta (rds/, files/, stream/)"
  value       = module.bucket["raw"].bucket_name
}

output "transformed_bucket_name" {
  description = "Transformed zone: cleaned, typed Delta tables"
  value       = module.bucket["transformed"].bucket_name
}

output "curated_bucket_name" {
  description = "Curated zone: star schema and aggregates"
  value       = module.bucket["curated"].bucket_name
}

output "source_files_bucket_name" {
  description = "Bucket that stands in for the external sources"
  value       = module.bucket["source-files"].bucket_name
}

output "glue_assets_bucket_name" {
  description = "Bucket holding Glue scripts, temp files and Athena results"
  value       = module.bucket["glue-assets"].bucket_name
}

output "glue_load_mysql_job_name" {
  description = "Glue job that loads the Olist CSVs into RDS MySQL"
  value       = module.glue.load_mysql_job_name
}

output "glue_ingest_job_name" {
  description = "Glue job that exports the MySQL tables to landing"
  value       = module.glue.ingest_job_name
}

output "glue_stream_job_name" {
  description = "Glue streaming job that writes the MSK topic to landing"
  value       = module.glue.stream_job_name
}

output "glue_landing_to_raw_job_name" {
  description = "Glue job that promotes every landing source to raw Delta tables"
  value       = module.glue.landing_to_raw_job_name
}

output "glue_raw_to_transformed_job_name" {
  description = "Glue job that builds the transformed zone (null while enable_transformed_zone = false)"
  value       = module.glue.raw_to_transformed_job_name
}

output "glue_transformed_to_curated_job_name" {
  description = "Glue job that builds the curated zone (null while enable_curated_zone = false)"
  value       = module.glue.transformed_to_curated_job_name
}

output "datasync_task_arn" {
  description = "DataSync task that copies source files to landing"
  value       = module.datasync.task_arn
}

output "msk_bootstrap_brokers_iam" {
  description = "MSK bootstrap brokers (SASL/IAM, TLS, port 9098)"
  value       = module.msk.bootstrap_brokers_iam
}

output "kafka_topic" {
  description = "Kafka topic of the streaming source"
  value       = var.kafka_topic
}

output "producer_instance_id" {
  description = "EC2 producer instance (SSM Run Command target)"
  value       = module.kafka_producer.instance_id
}

output "glue_database_names" {
  description = "Glue database per zone"
  value       = module.catalog.database_names
}

output "glue_crawler_names" {
  description = "Glue crawler per deployed zone"
  value       = module.catalog.crawler_names
}

output "athena_workgroup" {
  description = "Athena workgroup for lakehouse queries"
  value       = module.catalog.athena_workgroup
}

output "pipeline_state_machine_arn" {
  description = "Step Functions pipeline (scripts/run_pipeline.sh)"
  value       = module.orchestration.state_machine_arn
}

output "redshift_workgroup" {
  description = "Redshift Serverless workgroup (query editor v2)"
  value       = module.redshift.workgroup_name
}

output "redshift_database" {
  description = "Redshift database"
  value       = module.redshift.database_name
}

output "redshift_admin_secret_arn" {
  description = "Secret with the Redshift admin credentials"
  value       = module.redshift.admin_secret_arn
}

output "alerts_topic_arn" {
  description = "SNS topic for lakehouse alerts"
  value       = module.monitoring.alerts_topic_arn
}
