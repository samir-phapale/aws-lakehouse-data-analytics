output "instance_id" {
  description = "ID of the producer instance (target for SSM Run Command)"
  value       = aws_instance.this.id
}
