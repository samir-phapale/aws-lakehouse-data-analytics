output "task_arn" {
  description = "ARN of the source-files to landing DataSync task"
  value       = aws_datasync_task.this.arn
}
