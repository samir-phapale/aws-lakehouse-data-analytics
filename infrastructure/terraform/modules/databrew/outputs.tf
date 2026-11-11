output "role_arn" {
  description = "IAM role DataBrew jobs run as"
  value       = aws_iam_role.databrew.arn
}

output "profile_jobs" {
  description = "Transformed table -> DataBrew profile job name"
  value       = { for table, job in awscc_databrew_job.profile : table => job.name }
}

output "profile_job_arns" {
  description = "ARNs of the profile jobs"
  value       = [for job in awscc_databrew_job.profile : "arn:aws:databrew:${var.region}:${var.account_id}:job/${job.name}"]
}
