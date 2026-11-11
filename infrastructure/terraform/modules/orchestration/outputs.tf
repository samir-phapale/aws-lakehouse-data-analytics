output "state_machine_arn" {
  description = "Step Functions pipeline"
  value       = aws_sfn_state_machine.pipeline.arn
}

output "gate_role_arn" {
  description = "Role of the dq_gate Lambda (reads the transformed bucket)"
  value       = aws_iam_role.gate.arn
}
