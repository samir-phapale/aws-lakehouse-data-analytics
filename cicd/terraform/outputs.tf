output "github_connection_arn" {
  description = "GitHub connection; authorize it once in the console before the first run"
  value       = aws_codeconnections_connection.github.arn
}

output "codebuild_role_arn" {
  description = "CodeBuild role that runs terraform; add it as a Lake Formation data lake admin"
  value       = aws_iam_role.codebuild.arn
}
