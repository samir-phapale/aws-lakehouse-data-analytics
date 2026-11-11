output "database_names" {
  description = "Glue database per zone"
  value       = { for zone, db in aws_glue_catalog_database.zone : zone => db.name }
}

output "crawler_names" {
  description = "Glue crawler per deployed zone"
  value       = { for zone, crawler in aws_glue_crawler.zone : zone => crawler.name }
}

output "athena_workgroup" {
  description = "Athena workgroup for lakehouse queries"
  value       = aws_athena_workgroup.this.name
}

output "spectrum_database" {
  description = "Glue database with the curated tables as symlink-manifest tables (Redshift Spectrum)"
  value       = aws_glue_catalog_database.zone["spectrum"].name
}
