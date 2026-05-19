variable "name_prefix" {
  type        = string
  description = "Prefix for resource names"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for bootstrap instance"
}

variable "subnet_id" {
  type        = string
  description = "Private subnet ID (NAT egress; no public IP)"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version (e.g. 1.31) to pin kubectl to cluster version"
  default     = "1.31"
}

variable "node_role_arn" {
  type        = string
  description = "EKS node IAM role ARN for aws-auth mapRoles"
}

variable "admin_iam_users" {
  type        = list(string)
  default     = []
  description = "IAM usernames for aws-auth mapUsers (system:masters)"
}

variable "account_id" {
  type        = string
  description = "AWS account ID"
}

variable "alb_irsa_arn" {
  type        = string
  description = "ALB controller IRSA role ARN"
}

variable "external_secrets_irsa_arn" {
  type        = string
  description = "External Secrets IRSA role ARN"
}

variable "cluster_autoscaler_irsa_arn" {
  type        = string
  description = "Cluster Autoscaler IRSA role ARN"
}

variable "enable_external_dns" {
  type        = bool
  default     = false
  description = "Install External DNS"
}

variable "external_dns_irsa_arn" {
  type        = string
  default     = ""
  description = "External DNS IRSA role ARN"
}

variable "domain_name" {
  type        = string
  default     = ""
  description = "Domain for External DNS"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags (must include Environment, Name)"
}

variable "image_updater_irsa_arn" {
  type        = string
  description = "ArgoCD Image Updater IRSA role ARN"
}

variable "self_terminate" {
  type        = bool
  default     = true
  description = "Terminate instance after bootstrap completes"
}
