output "cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.this.arn
}

output "bootstrap_brokers_iam" {
  description = "Bootstrap brokers for SASL/IAM over TLS (port 9098)"
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
}
