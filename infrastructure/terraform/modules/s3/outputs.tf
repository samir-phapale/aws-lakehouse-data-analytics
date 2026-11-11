output "bucket_name" {
  description = "Name of the bucket"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the bucket"
  value       = aws_s3_bucket.this.arn

  # DataSync checks its access to the bucket when a location is created
  depends_on = [aws_s3_bucket_policy.this]
}
