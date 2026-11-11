output "address" {
  description = "Hostname of the instance"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port the instance listens on"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret RDS created for the master user"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
