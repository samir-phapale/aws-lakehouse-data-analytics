output "alerts_topic_arn" {
  description = "SNS topic for lakehouse alerts"
  value       = aws_sns_topic.alerts.arn
}

output "remediation_role_arn" {
  description = "Role SSM uses to remediate non-compliant buckets (must be in the bucket allow-lists)"
  value       = aws_iam_role.remediation.arn
}
