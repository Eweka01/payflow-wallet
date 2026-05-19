output "bootstrap_instance_id" {
  description = "Bootstrap instance ID. If Ingress stays Pending, bootstrap may have failed: check /var/log/bootstrap.log via SSM, terminate this instance, then terraform apply again. See docs/BOOTSTRAP-TROUBLESHOOTING.md"
  value       = module.bootstrap_node.instance_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.payflow.name
}

output "eks_cluster_id" {
  description = "EKS Cluster ID"
  value       = aws_eks_cluster.payflow.id
}

output "eks_cluster_arn" {
  description = "EKS Cluster ARN"
  value       = aws_eks_cluster.payflow.arn
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster API endpoint"
  value       = aws_eks_cluster.payflow.endpoint
}

output "eks_cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id
}

output "eks_node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes (pod traffic egresses with this SG)"
  value       = aws_security_group.eks_nodes.id
}

output "eks_oidc_provider_arn" {
  description = "ARN of the EKS OIDC Provider"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.eks_node.arn
}

# ECR Repository Outputs
output "ecr_repository_urls" {
  description = "ECR repository URLs for all services"
  value = {
    api_gateway          = aws_ecr_repository.api_gateway.repository_url
    auth_service         = aws_ecr_repository.auth_service.repository_url
    wallet_service       = aws_ecr_repository.wallet_service.repository_url
    transaction_service  = aws_ecr_repository.transaction_service.repository_url
    notification_service = aws_ecr_repository.notification_service.repository_url
    frontend             = aws_ecr_repository.frontend.repository_url
    db_migrations        = aws_ecr_repository.db_migrations.repository_url
  }
}

# ============================================================
# ArgoCD Webhook Outputs
# ============================================================

output "argocd_webhook_url" {
  description = "Paste this URL into GitHub repo → Settings → Webhooks → Payload URL"
  value       = "${aws_apigatewayv2_api.argocd_webhook.api_endpoint}/webhook"
}

output "argocd_webhook_post_deploy_steps" {
  description = "Manual steps required after terraform apply to activate the webhook"
  value       = <<-EOT

    ── Step 1: Make ArgoCD internal-only ────────────────────────────────────────
    Run from the bastion host (SSM session):

      kubectl patch svc argocd-server -n argocd \
        -p '{"metadata":{"annotations":{"service.beta.kubernetes.io/aws-load-balancer-internal":"true","service.beta.kubernetes.io/aws-load-balancer-scheme":"internal"}},"spec":{"type":"LoadBalancer"}}'

      # Wait ~60s, then get the internal NLB DNS:
      kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

    ── Step 2: Store ArgoCD internal URL in Secrets Manager ─────────────────────
      ARGOCD_NLB=<paste NLB DNS from above>

      aws secretsmanager put-secret-value \
        --secret-id payflow/${local.env}/argocd-internal-url \
        --secret-string "https://$ARGOCD_NLB" \
        --region ${var.aws_region}

    ── Step 3: Create ArgoCD service account + token ────────────────────────────
    In the ArgoCD UI or via CLI on the bastion:

      argocd account generate-token --account admin --grpc-web

    Store the token:
      aws secretsmanager put-secret-value \
        --secret-id payflow/${local.env}/argocd-token \
        --secret-string "<paste token>" \
        --region ${var.aws_region}

    ── Step 4: Generate and store the webhook secret ────────────────────────────
      WEBHOOK_SECRET=$(openssl rand -hex 32)
      echo "Your webhook secret: $WEBHOOK_SECRET"

      aws secretsmanager put-secret-value \
        --secret-id payflow/${local.env}/github-webhook-secret \
        --secret-string "$WEBHOOK_SECRET" \
        --region ${var.aws_region}

    ── Step 5: Configure GitHub webhook ─────────────────────────────────────────
    Go to: GitHub repo → Settings → Webhooks → Add webhook
      Payload URL:  ${aws_apigatewayv2_api.argocd_webhook.api_endpoint}/webhook
      Content type: application/json
      Secret:       <the WEBHOOK_SECRET from step 4>
      Events:       Just the push event
      Active:       ✓

    ── Done ─────────────────────────────────────────────────────────────────────
    Next push to main will sync ArgoCD in seconds instead of up to 3 minutes.
  EOT
}


output "ecr_repository_arns" {
  description = "ECR repository ARNs for all services"
  value = {
    api_gateway          = aws_ecr_repository.api_gateway.arn
    auth_service         = aws_ecr_repository.auth_service.arn
    wallet_service       = aws_ecr_repository.wallet_service.arn
    transaction_service  = aws_ecr_repository.transaction_service.arn
    notification_service = aws_ecr_repository.notification_service.arn
    frontend             = aws_ecr_repository.frontend.arn
    db_migrations        = aws_ecr_repository.db_migrations.arn
  }
}

output "image_updater_irsa_arn" {
  description = "IAM role ARN for ArgoCD Image Updater (annotate its ServiceAccount with this)"
  value       = aws_iam_role.image_updater_irsa.arn
}

# Secrets Manager Outputs
output "secrets_manager_arns" {
  description = "Secrets Manager ARNs"
  value = {
    rds      = aws_secretsmanager_secret.rds.arn
    rabbitmq = aws_secretsmanager_secret.rabbitmq.arn
    redis    = aws_secretsmanager_secret.redis.arn
    app      = aws_secretsmanager_secret.app_secrets.arn
  }
  sensitive = true
}

# WAF Outputs
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.payflow.arn
}

# Route53 Outputs
output "route53_zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = var.domain_name != "" ? aws_route53_zone.payflow[0].zone_id : null
}

output "acm_certificate_arn" {
  description = "ACM Certificate ARN"
  value       = var.domain_name != "" ? aws_acm_certificate_validation.payflow[0].certificate_arn : null
}

# GuardDuty Outputs (prod only)
output "guardduty_detector_id" {
  description = "GuardDuty Detector ID (null in dev)"
  value       = local.env == "prod" ? aws_guardduty_detector.payflow[0].id : null
}

# ALB Controller IRSA Role (for Ingress → ALB)
output "alb_controller_irsa_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (install with Helm if missing)"
  value       = aws_iam_role.alb_controller_irsa.arn
}

# External Secrets IRSA Role
output "external_secrets_irsa_arn" {
  description = "External Secrets IRSA Role ARN"
  value       = aws_iam_role.external_secrets_irsa.arn
}

# Cluster Autoscaler IRSA Role
output "cluster_autoscaler_irsa_arn" {
  description = "Cluster Autoscaler IRSA Role ARN"
  value       = aws_iam_role.cluster_autoscaler_irsa.arn
}

