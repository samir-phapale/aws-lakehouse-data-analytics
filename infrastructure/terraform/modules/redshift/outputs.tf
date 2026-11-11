output "role_arn" {
  description = "IAM role Redshift uses for Spectrum"
  value       = aws_iam_role.redshift.arn
}

output "workgroup_name" {
  description = "Redshift Serverless workgroup"
  value       = aws_redshiftserverless_workgroup.this.workgroup_name
}

output "database_name" {
  description = "Redshift database"
  value       = aws_redshiftserverless_namespace.this.db_name
}

output "admin_secret_arn" {
  description = "Secrets Manager secret with the admin credentials (managed by Redshift)"
  value       = aws_redshiftserverless_namespace.this.admin_password_secret_arn
}

output "workgroup_arn" {
  description = "Redshift Serverless workgroup ARN"
  value       = aws_redshiftserverless_workgroup.this.arn
}
