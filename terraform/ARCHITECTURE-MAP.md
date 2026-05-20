# PayFlow Terraform Architecture Map

This document maps every resource, dependency order, cycles, IAM roles, security groups, and environment boundaries across the Terraform codebase.

**Companion docs and visuals:** [terraform.md](terraform.md) (narrative hub-and-spoke model) · [EKS VPC integration diagram (PNG)](../docs/assets/EKS%20VPC%20Integration%20Pipeline-2026-03-30-135753.png) · [docs index](../docs/README.md#aws-eks-infrastructure-first-time).

---

## 1. Architecture Diagram (Every Resource → Box, Every Relationship → Arrow)

### 1.1 Module-level view (cross-stack)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  BOOTSTRAP (terraform/bootstrap)                                                     │
│  S3 bucket (payflow-tfstate-ACCOUNT) + DynamoDB lock table                           │
│  Run once before any other module. All other backends reference this bucket.         │
└──────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────────┐
│  HUB VPC (terraform/aws/hub-vpc)                                                     │
│  aws_vpc.hub → subnets (hub_public, hub_private) → route tables                     │
│  → aws_ec2_transit_gateway.hub → aws_ec2_transit_gateway_vpc_attachment.hub          │
│  aws_route.hub_public_to_eks → var.spoke_vpc_cidr via TGW                           │
└──────────────────────────────────────────────────────────────────────────────────────┘
          │
          │  (Spoke reads: data.aws_vpc.hub, data.aws_ec2_transit_gateway.hub,
          │   data.aws_route_table.hub_private — data sources, no TF dependency)
          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  SPOKE VPC EKS (terraform/aws/spoke-vpc-eks)                                         │
│  aws_vpc.eks (10.10.0.0/16)                                                          │
│    → subnets, IGW, EIP, NAT GW, route tables                                        │
│    → TGW attachment → aws_route.hub_to_eks (writes back to hub private RT)           │
│    → VPC Flow Logs (CloudWatch)                                                      │
│    → aws_eks_cluster.payflow (private endpoint only)                                 │
│        → OIDC → IRSA roles (6) → addons → node group → Helm releases                │
│    → Lambda + API Gateway (ArgoCD webhook receiver)                                  │
│    → ECR (7 repos) · WAF · GuardDuty · CloudTrail · Security Hub · AWS Config       │
│    → Secrets Manager (KMS CMK) · Route53/ACM (optional)                             │
└──────────────────────────────────────────────────────────────────────────────────────┘
          │  outputs: eks_cluster_security_group_id, argocd_webhook_url, waf_web_acl_arn, etc.
          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  MANAGED SERVICES (terraform/aws/managed-services)                                   │
│  [input: var.eks_node_security_group_id from spoke output]                           │
│  RDS PostgreSQL · ElastiCache Redis · Amazon MQ RabbitMQ                            │
│  Each with a dedicated SG allowing ingress from EKS node/cluster SG only            │
└──────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────────┐
│  BASTION (terraform/aws/bastion)                                                     │
│  [data: hub VPC, hub public subnet]                                                  │
│  aws_security_group.bastion → aws_instance.bastion (IAM instance profile)           │
│  Primary access: SSM Session Manager (AmazonSSMManagedInstanceCore policy)          │
│  Fallback: SSH port 22 restricted to var.authorized_ssh_cidrs                        │
└──────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────────┐
│  GITHUB ACTIONS (terraform/aws/github-actions)                                       │
│  aws_iam_openid_connect_provider.github_actions (GitHub OIDC)                        │
│  aws_iam_role.github_actions → aws_iam_policy.ecr (push to 7 ECR repos)             │
│  CI pipeline assumes this role via OIDC — no static AWS keys                        │
└──────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────────┐
│  FINOPS (terraform/aws/finops)                                                       │
│  AWS Budgets · CloudWatch billing alarm · Cost Anomaly Detection (optional)          │
│  Cost allocation tags (enable_cost_allocation_tags = false on first apply)           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Spoke EKS — resource-level dependency graph

```
[Data sources: aws_vpc.hub, aws_ec2_transit_gateway.hub, aws_route_table.hub_private]

aws_vpc.eks (10.10.0.0/16)
  ├─► aws_subnet.eks_public[*], aws_subnet.eks_private[*]
  ├─► aws_internet_gateway.eks
  ├─► aws_route_table.eks_public[*], aws_route_table.eks_private[*], associations
  ├─► aws_eip.nat[*] → aws_nat_gateway.eks[*] → aws_route.eks_private[*]
  ├─► aws_ec2_transit_gateway_vpc_attachment.eks → aws_subnet.eks_private[*]
  ├─► aws_route.hub_to_eks (writes to hub private RT via data source)
  │
  ├─► aws_iam_role.flow_logs + aws_iam_role_policy.flow_logs
  │     └─► time_sleep.wait_for_flow_logs_iam
  │           └─► aws_cloudwatch_log_group.flow_logs → aws_flow_log.eks
  │
  ├─► aws_iam_role.eks_cluster + policy attachments
  │     └─► time_sleep.wait_for_cluster_iam
  ├─► aws_kms_key.eks + aws_cloudwatch_log_group.eks_cluster
  ├─► aws_eks_cluster.payflow (private endpoint only)
  │     └─► time_sleep.wait_for_cluster
  │           └─► data.tls_certificate.eks
  │                 └─► aws_iam_openid_connect_provider.eks
  │
  ├─► IRSA roles (all depend on OIDC):
  │     vpc_cni_irsa, alb_controller_irsa, external_dns_irsa, ebs_csi_irsa,
  │     cluster_autoscaler_irsa, image_updater_irsa
  │     + external_secrets_irsa (in secrets-manager.tf)
  │     └─► time_sleep.wait_for_irsa / time_sleep.wait_for_external_secrets_irsa
  │
  ├─► aws_eks_addon.vpc_cni → wait_for_cluster, wait_for_irsa
  │
  ├─► aws_iam_role.eks_node + 4 policy attachments
  │     └─► time_sleep.wait_for_node_iam
  ├─► aws_eks_node_group.payflow (single group; SPOT t3.large in dev, ON_DEMAND elsewhere)
  │     depends_on: wait_for_node_iam, vpc_cni addon
  │     dev:  desired=2, min=1, max=3, t3.large, SPOT
  │     prod: desired=3, min=2, max=10, t3.large, ON_DEMAND
  │
  ├─► aws_eks_addon.coredns, kube_proxy, ebs_csi → node group + vpc_cni
  ├─► kubernetes_config_map_v1_data.aws_auth → cluster + node group
  │
  ├─► Helm releases:
  │     alb_controller → alb_controller_irsa
  │     external_dns   → external_dns_irsa
  │     metrics_server
  │     cluster_autoscaler → cluster_autoscaler_irsa
  │     external_secrets → external_secrets_irsa
  │
  ├─► ECR repositories (7 — no EKS dep, created independently):
  │     api_gateway, auth_service, wallet_service, transaction_service,
  │     notification_service, db_migrations, frontend
  │
  ├─► Secrets Manager + KMS CMK:
  │     aws_kms_key.secrets (CMK — every decrypt logged to CloudTrail)
  │     secrets: rds, redis, rabbitmq, jwt, github-webhook-secret (placeholder),
  │              argocd-token (placeholder), argocd-internal-url (placeholder)
  │
  ├─► Lambda + API Gateway (ArgoCD webhook):
  │     aws_secretsmanager_secret: github_webhook_secret, argocd_token, argocd_internal_url
  │     aws_iam_role.argocd_webhook_lambda + inline policy
  │     aws_security_group.argocd_webhook_lambda (private subnets, HTTPS egress only)
  │     data.archive_file.argocd_webhook → aws_lambda_function.argocd_webhook
  │       (Python 3.12, HMAC-SHA256 validation, env vars encrypted with KMS)
  │     aws_cloudwatch_log_group.argocd_webhook_lambda
  │     aws_apigatewayv2_api.argocd_webhook (HTTP v2)
  │       → aws_apigatewayv2_integration.lambda
  │       → aws_apigatewayv2_route.webhook (POST /webhook)
  │       → aws_apigatewayv2_stage.default ($default, auto-deploy)
  │     aws_cloudwatch_log_group.argocd_webhook_api
  │     aws_lambda_permission.api_gateway
  │
  ├─► WAF:
  │     aws_wafv2_web_acl.payflow (REGIONAL, AWS managed rules + rate limit)
  │     aws_wafv2_web_acl_logging_configuration.payflow
  │     (attached to ALB via annotation on Ingress — not a TF association)
  │
  ├─► Security:
  │     aws_guardduty_detector.payflow
  │     aws_cloudtrail.eks → S3 bucket + CloudWatch log group
  │     aws_securityhub_account.payflow
  │       → aws_securityhub_standards_subscription.cis
  │       → aws_securityhub_standards_subscription.aws_foundational
  │     AWS Config (aws_iam_role.config + delivery channel + recorder)
  │
  └─► Route53 / ACM (optional — skip if no domain):
        aws_route53_zone, aws_acm_certificate (DNS validation)
```

---

## 2. Dependency Order (What Must Exist First)

1. **Bootstrap:** S3 state bucket + DynamoDB lock table. Run once. All other modules depend on this bucket for their backend.
2. **Hub networking:** `aws_vpc.hub` → subnets → TGW → TGW attachment → route `hub_public_to_eks`.
3. **Spoke networking:** `aws_vpc.eks` → subnets → IGW → EIP → NAT GW → route tables → TGW attachment → `aws_route.hub_to_eks`.
4. **Spoke flow logs:** flow log IAM role → `time_sleep.wait_for_flow_logs_iam` → CW log group → `aws_flow_log.eks`.
5. **Spoke EKS cluster IAM:** cluster role + attachments → `time_sleep.wait_for_cluster_iam`.
6. **Spoke EKS cluster:** KMS key + CW log group → `aws_eks_cluster.payflow` → `time_sleep.wait_for_cluster`.
7. **OIDC:** `data.tls_certificate.eks` → `aws_iam_openid_connect_provider.eks`.
8. **IRSA roles:** all 7 IRSA roles + policies/attachments → `time_sleep.wait_for_irsa` / `time_sleep.wait_for_external_secrets_irsa`.
9. **VPC CNI addon:** after wait_for_cluster + wait_for_irsa.
10. **Node IAM:** `aws_iam_role.eks_node` + 4 attachments → `time_sleep.wait_for_node_iam`.
11. **Node group:** after wait_for_node_iam + cluster + vpc_cni addon.
12. **Addons:** coredns, kube_proxy, ebs_csi — after node group + vpc_cni.
13. **Kubernetes:** `aws_auth` ConfigMap — after cluster + node group.
14. **Helm:** alb_controller → external_dns; metrics_server; cluster_autoscaler; external_secrets.
15. **Lambda + API GW:** no EKS dependency — can apply in parallel with Helm or after. Secrets (webhook, ArgoCD token, URL) are placeholders; replaced post-deploy.
16. **Managed services (separate apply):** after spoke is complete; pass `eks_cluster_security_group_id` → RDS/Redis/MQ SGs and instances.
17. **Bastion, GitHub Actions, FinOps:** independent; apply after hub or in parallel (no EKS dep).

---

## 3. Cycle Check

All edges are directed and acyclic:

- **Spoke EKS:** VPC → networking → cluster IAM → cluster → OIDC → IRSA → vpc_cni → node group → addons → aws-auth → Helm. Lambda/API GW branch is parallel, no back-edges. ✓
- **Hub:** VPC → subnets → TGW → attachment → route. No back-edge. ✓
- **Managed services:** reads data sources + variable input from spoke. Produces no output consumed by spoke in Terraform. ✓
- **Bastion:** data (hub VPC, subnet) → SG → instance. ✓
- **GitHub Actions:** OIDC provider → IAM role → policy. ✓
- **Cross-stack:** Spoke reads hub via **data sources** (no Terraform dep). Spoke **writes** `aws_route.hub_to_eks` in its own apply (operational ordering via spinup.sh, not a graph cycle). ✓

**Conclusion: No dependency cycles.**

---

## 4. IAM Roles and What They Attach To

| IAM Role | Module | Principal / Used By | Policies Attached | Purpose |
|----------|--------|---------------------|-------------------|---------|
| **eks_cluster** | spoke-vpc-eks | `eks.amazonaws.com` | AmazonEKSClusterPolicy | EKS control plane |
| **eks_node** | spoke-vpc-eks | `ec2.amazonaws.com` (node group) | EKSWorkerNodePolicy, EKS_CNI_Policy, ECR ReadOnly, SSMManagedInstanceCore | Worker nodes |
| **vpc_cni_irsa** | spoke-vpc-eks | OIDC `kube-system:aws-node` | AmazonEKS_CNI_Policy | VPC CNI addon (IRSA) |
| **alb_controller_irsa** | spoke-vpc-eks | OIDC `kube-system:aws-load-balancer-controller` | Inline (ALB/NLB, EC2, tags) | ALB Ingress Controller |
| **external_dns_irsa** | spoke-vpc-eks | OIDC `kube-system:external-dns` | Inline (Route53 ChangeRRSet, List*) | External DNS |
| **ebs_csi_irsa** | spoke-vpc-eks | OIDC `kube-system:ebs-csi-controller-sa` | AmazonEBSCSIDriverPolicy | EBS CSI addon |
| **cluster_autoscaler_irsa** | spoke-vpc-eks | OIDC `kube-system:cluster-autoscaler` | Inline (ASG describe/set desired, EC2 describe) | Cluster Autoscaler |
| **image_updater_irsa** | spoke-vpc-eks | OIDC `argocd:argocd-image-updater` | Inline (ECR DescribeImages, BatchGetImage) | ArgoCD Image Updater — polls ECR for new tags |
| **external_secrets_irsa** | spoke-vpc-eks | OIDC `external-secrets:external-secrets` | Inline (Secrets Manager GetSecretValue, KMS Decrypt) | External Secrets Operator |
| **argocd_webhook_lambda** | spoke-vpc-eks | `lambda.amazonaws.com` | Inline (Secrets Manager, KMS, VPC ENI, CloudWatch Logs) | Lambda webhook receiver for ArgoCD |
| **flow_logs** | spoke-vpc-eks | `vpc-flow-logs.amazonaws.com` | Inline (CreateLogGroup, PutLogEvents, Describe*) | VPC Flow Logs |
| **config** | spoke-vpc-eks | `config.amazonaws.com` | AWS_ConfigRole + custom S3 delivery | AWS Config |
| **bastion** | bastion | `ec2.amazonaws.com` (instance profile) | Inline (eks:DescribeCluster, ssm:StartSession) + AmazonSSMManagedInstanceCore | Bastion host — SSM access + EKS describe |
| **github_actions** | github-actions | GitHub OIDC (`token.actions.githubusercontent.com`) | Inline (ECR GetAuthToken, BatchCheckLayer, PutImage, etc. on 7 repos) | CI pipeline — OIDC role, no static AWS keys |

**Attach relationship summary:**

```
EKS cluster              → eks_cluster
Node group               → eks_node
VPC CNI addon            → vpc_cni_irsa (IRSA)
EBS CSI addon            → ebs_csi_irsa (IRSA)
Helm: alb_controller     → alb_controller_irsa (IRSA)
Helm: external_dns       → external_dns_irsa (IRSA)
Helm: cluster_autoscaler → cluster_autoscaler_irsa (IRSA)
Helm: external_secrets   → external_secrets_irsa (IRSA)
ArgoCD Image Updater     → image_updater_irsa (IRSA)
Lambda argocd_webhook    → argocd_webhook_lambda
aws_flow_log.eks         → flow_logs
AWS Config               → config
Bastion EC2 instance     → bastion (via instance profile)
GitHub Actions CI        → github_actions (via OIDC token)
```

---

## 5. Security Groups: Ingress/Egress

### 5.1 Spoke EKS module

No custom security groups defined in the EKS Terraform for the cluster itself. The cluster uses the **AWS-managed cluster security group** from `aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id`. This SG ID is exported as `eks_cluster_security_group_id` and passed to managed-services.

**Lambda SG (argocd_webhook_lambda):**

| SG | VPC | Ingress | Egress |
|----|-----|---------|--------|
| `aws_security_group.argocd_webhook_lambda` | EKS VPC | None (API GW invokes via Lambda URL) | TCP 443 to VPC (ArgoCD NLB), TCP 443 to 0.0.0.0/0 (Secrets Manager) |

### 5.2 Managed services

| SG | VPC | Ingress | Egress | References other SG? |
|----|-----|---------|--------|----------------------|
| **aws_security_group.rds** | EKS VPC | TCP 5432 from `var.eks_node_security_group_id` | All 0.0.0.0/0 | Yes → EKS cluster SG (input var) |
| **aws_security_group.elasticache** | EKS VPC | TCP 6379 from `var.eks_node_security_group_id` | All 0.0.0.0/0 | Yes → EKS cluster SG (input var) |
| **aws_security_group.mq** | EKS VPC | TCP 5671, 15671 from `var.eks_node_security_group_id` | All 0.0.0.0/0 | Yes → EKS cluster SG (input var) |

### 5.3 Bastion

| SG | VPC | Ingress | Egress |
|----|-----|---------|--------|
| `aws_security_group.bastion` | Hub VPC | TCP 22 from `var.authorized_ssh_cidrs` (fallback only — primary access is SSM, no port 22 needed) | TCP 443 to 10.0.0.0/8 (EKS API, SSM, MQ tunnel); UDP 53 to 0.0.0.0/0 |

**Summary:** No circular SG references. Only RDS, ElastiCache, and MQ reference another SG (the EKS cluster SG), one-way.

---

## 6. Environment Boundaries and Remote State

### 6.1 Environment-specific vs shared

| Scope | Shared | Environment-specific |
|-------|--------|----------------------|
| **Account/Region** | Same AWS account and region for all modules | Can split accounts per env — not in current layout |
| **Hub VPC** | One hub per account (TGW, hub subnets, hub route table) | `var.hub_vpc_cidr`, `var.spoke_vpc_cidr` can differ per env |
| **Spoke EKS** | Same module layout | `var.environment` drives `local.env` → node config lookup (SPOT dev vs ON_DEMAND prod) |
| **Managed services** | Same module layout | DB/Redis/MQ sizing, `var.eks_node_security_group_id` from spoke |
| **Bastion** | One per hub | `var.authorized_ssh_cidrs` |
| **Node config** | Defined in `locals.tf` node_config map | `local.env = var.environment` — dev gets SPOT t3.large; prod gets ON_DEMAND t3.large ×3 |

> **Important:** `local.env = var.environment` (set in `terraform.tfvars`). It does **not** use `terraform.workspace`. All state lives in the `default` workspace.

### 6.2 Remote state keys (all modules)

| Module | State key | Backend |
|--------|-----------|---------|
| **bootstrap** | *(local or manual)* | Local |
| **hub-vpc** | `aws/hub-vpc/terraform.tfstate` | S3 + DynamoDB |
| **spoke-vpc-eks** | `aws/eks/terraform.tfstate` | S3 + DynamoDB |
| **bastion** | `aws/bastion/terraform.tfstate` | S3 + DynamoDB |
| **managed-services** | `aws/managed-services/terraform.tfstate` | S3 + DynamoDB |
| **finops** | `aws/finops/terraform.tfstate` | S3 + DynamoDB |
| **github-actions** | `aws/github-actions/terraform.tfstate` | S3 + DynamoDB |

All S3 backends use bucket `payflow-tfstate-ACCOUNT_ID`, DynamoDB table `payflow-tfstate-lock`.

### 6.3 Cross-stack data flow

```
bootstrap
  └─► creates S3 bucket + DynamoDB → all other module backends point here

hub-vpc
  └─► TGW ID, hub VPC ID, hub subnet IDs
        (read by spoke-vpc-eks as data sources — not terraform_remote_state)

spoke-vpc-eks outputs
  ├─► eks_cluster_security_group_id  → var input to managed-services
  ├─► argocd_webhook_url             → paste into GitHub repo webhook settings
  ├─► waf_web_acl_arn                → paste into helm/payflow/values-dev.yaml
  ├─► acm_certificate_arn            → paste into helm/payflow/values-dev.yaml
  ├─► image_updater_irsa_arn         → setup-cluster.sh reads this
  ├─► external_secrets_irsa_arn      → setup-cluster.sh reads this
  ├─► alb_controller_irsa_arn        → setup-cluster.sh reads this
  ├─► ecr_repository_urls            → referenced in helm values + CI
  └─► guardduty_detector_id          → destroy.sh verification
```

---

## 7. Quick Reference

| Question | Answer |
|----------|--------|
| **Dependency loop?** | No. All modules are acyclic. |
| **SG circular reference?** | No. RDS/Redis/MQ reference EKS node SG one-way (input variable). |
| **First resource in spoke EKS?** | `aws_vpc.eks` (parallel: cluster IAM, KMS, flow log IAM). |
| **EKS endpoint public?** | No. `endpoint_public_access = false`. All kubectl via SSM bastion. |
| **Node group type in dev?** | Single node group, SPOT t3.large, desired=2, min=1, max=3. |
| **Node group type in prod?** | Single node group, ON_DEMAND t3.large, desired=3, min=2, max=10. |
| **How is env set?** | `local.env = var.environment` in `locals.tf`. Set via `terraform.tfvars`. Not workspace. |
| **How many ECR repos?** | 7: api_gateway, auth_service, wallet_service, transaction_service, notification_service, db_migrations, frontend. |
| **How many IAM roles?** | 14: cluster, node, 7 IRSA, lambda webhook, flow_logs, config, bastion, github_actions. |
| **Remote state** | All modules: S3 bucket `payflow-tfstate-ACCOUNT_ID` + DynamoDB lock. Workspace = default for all. |
| **Lambda webhook** | API Gateway HTTP v2 → Python 3.12 Lambda in private subnets → ArgoCD NLB. HMAC-SHA256 validated. |
| **Secrets pattern** | KMS CMK → Secrets Manager → ESO ClusterSecretStore → K8s secrets. Paths: `payflow/dev/...`. |
