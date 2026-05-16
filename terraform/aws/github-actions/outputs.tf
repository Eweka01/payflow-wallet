output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions workflows assume via OIDC"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
