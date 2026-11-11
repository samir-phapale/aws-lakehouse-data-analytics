output "key_arn" {
  description = "ARN of the lakehouse KMS key"
  value       = aws_kms_key.this.arn
}
