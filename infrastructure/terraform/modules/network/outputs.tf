output "vpc_id" {
  description = "ID of the lakehouse VPC"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "private_subnet_azs" {
  description = "Availability zone of each private subnet, same order as private_subnet_ids"
  value       = aws_subnet.private[*].availability_zone
}

output "glue_security_group_id" {
  description = "Security group for Glue job ENIs"
  value       = aws_security_group.glue.id
}

output "rds_security_group_id" {
  description = "Security group for the RDS source database"
  value       = aws_security_group.rds.id
}

output "msk_security_group_id" {
  description = "Security group for the MSK brokers"
  value       = aws_security_group.msk.id
}

output "producer_security_group_id" {
  description = "Security group for the EC2 Kafka producer"
  value       = aws_security_group.producer.id
}
