output "glue_ingest_role_arn" {
  description = "Glue ingest role (landing zone): MySQL loader, MySQL -> landing, MSK -> landing"
  value       = aws_iam_role.glue_ingest.arn
}

output "glue_lakehouse_role_arn" {
  description = "Glue lakehouse role (lake house): landing -> raw -> transformed -> curated"
  value       = aws_iam_role.glue_lakehouse.arn
}

output "datasync_role_arn" {
  description = "Role DataSync assumes to read the source bucket and write landing"
  value       = aws_iam_role.datasync.arn
}

output "producer_role_arn" {
  description = "Role of the EC2 Kafka producer"
  value       = aws_iam_role.producer.arn
}

output "producer_instance_profile_name" {
  description = "Instance profile for the EC2 Kafka producer"
  value       = aws_iam_instance_profile.producer.name
}

output "glue_crawler_role_arn" {
  description = "Glue crawler role (data governance): reads the zone buckets, writes the catalog"
  value       = aws_iam_role.glue_crawler.arn
}
