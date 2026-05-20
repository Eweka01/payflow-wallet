# Terraform Architecture

Our architecture uses a **hub-and-spoke design** with **Transit Gateway** connecting VPCs. Each VPC manages its own egress (NAT or Internet Gateway), which keeps the setup simple and isolated.

---

## Overview

- **Hub VPC** holds shared network services: the Transit Gateway and bastion host. It is the central connectivity point between VPCs.
- **Spoke VPC (EKS)** holds the Kubernetes cluster, application workloads, managed services (RDS, Redis, MQ), and the Lambda webhook receiver.
- **Egress** is not centralized: the spoke uses its own NAT gateways for outbound internet; the hub's public subnet uses an Internet Gateway. There is no single egress VPC or shared NAT.
- **EKS API endpoint is private** (`endpoint_public_access = false`). All `kubectl` and `helm` commands run via SSM session on the bastion.

![EKS VPC hub-and-spoke integration pipeline](../docs/assets/EKS%20VPC%20Integration%20Pipeline-2026-03-30-135753.png)

*Same figure appears in [docs/architecture.md](../docs/architecture.md#infrastructure) and [INFRASTRUCTURE-ONBOARDING.md](../docs/INFRASTRUCTURE-ONBOARDING.md).*

---

## Hub VPC

| Component | Purpose |
|-----------|---------|
| **CIDR** | `10.0.0.0/16` |
| **Public subnet** | Bastion host; route `0.0.0.0/0` → IGW. Also has route to **spoke VPC CIDR** via TGW so bastion can reach EKS. |
| **Private subnet** | Reserved for shared services; no default internet route. |
| **Transit Gateway** | Created in the hub; hub and spoke both attach. |
| **TGW attachment** | Hub attaches to TGW via public + private subnets. |

**Traffic:** Bastion → EKS uses: Hub public subnet → route to spoke CIDR via TGW → Spoke VPC. Return: Spoke public subnet has a route for hub VPC CIDR via TGW.

---

## Spoke VPC (EKS)

| Component | Purpose |
|-----------|---------|
| **CIDR** | `10.10.0.0/16` |
| **Public subnets** | One per AZ. NAT gateways, ALB. Route: hub CIDR → TGW (return path to bastion). |
| **Private subnets** | One per AZ. EKS node group, Lambda, workloads. Route: `10.0.0.0/8` → TGW; `0.0.0.0/0` → NAT. |
| **Transit Gateway attachment** | Spoke attaches to TGW via **private subnets** only. |
| **NAT gateways** | One per AZ in public subnets; private subnet default route goes through local NAT. |
| **EKS cluster** | Control plane. **Private endpoint only** — no public API access. All kubectl via SSM bastion. |
| **EKS node group** | Single node group in private subnets. Config driven by `var.environment` → `local.env`: dev = SPOT t3.large (desired 2, min 1, max 3); prod = ON_DEMAND t3.large (desired 3, min 2, max 10). |
| **VPC endpoints** | ECR, S3, STS, Secrets Manager — private DNS; AWS API traffic stays off NAT. |
| **Lambda (ArgoCD webhook)** | Python 3.12 in private subnets. API Gateway HTTP v2 (public URL) → Lambda validates HMAC-SHA256 → triggers ArgoCD sync. |
| **ECR repositories** | 7 repos: api_gateway, auth_service, wallet_service, transaction_service, notification_service, db_migrations, frontend. Immutable tags. |
| **KMS + Secrets Manager** | Customer-managed KMS key. Every secret decrypt logged to CloudTrail. ESO reads secrets at paths `payflow/{env}/...` |
| **WAF** | `aws_wafv2_web_acl.payflow` (REGIONAL). AWS managed rules + rate limiting. Attached to ALB via Ingress annotation — not a Terraform association. |
| **GuardDuty** | Threat detection enabled for the account. |
| **CloudTrail** | Multi-region trail; logs to S3 + CloudWatch. Every API call — including KMS decrypts and SSM sessions — is audited. |
| **Security Hub** | CIS AWS Foundations + AWS Foundational Security Best Practices standards enabled. |
| **AWS Config** | Resource configuration recorder + delivery channel. |

### Managed services (terraform/aws/managed-services)

RDS, ElastiCache, and Amazon MQ live **in the same spoke VPC**, in the same private subnets used by EKS. They are not in a separate VPC.

| Resource | Purpose |
|----------|---------|
| **RDS PostgreSQL** | Private subnets; SG allows ingress TCP 5432 from EKS cluster SG only. |
| **ElastiCache Redis** | Private subnets; SG allows ingress TCP 6379 from EKS cluster SG only. |
| **Amazon MQ (RabbitMQ)** | Private subnets; SG allows ingress TCP 5671/15671 from EKS cluster SG only. |

---

## Hub Resources (hub-vpc + bastion modules)

| Resource | Purpose |
|----------|---------|
| **aws_vpc.hub** | CIDR `10.0.0.0/16`. |
| **Subnets** | Public (bastion), private (reserved). |
| **aws_internet_gateway.hub** | Internet for hub public subnet. |
| **Route tables** | Public: `0.0.0.0/0` → IGW, spoke CIDR → TGW. Private: spoke CIDR via TGW added by spoke Terraform. |
| **aws_ec2_transit_gateway.hub** | Shared TGW; both VPCs attach. |
| **TGW attachment** | Hub VPC attached (public + private subnets). |
| **Bastion EC2** | In hub public subnet. Primary access: **SSM Session Manager** (no SSH key, no open port). Fallback: SSH port 22 restricted to `var.authorized_ssh_cidrs`. IAM role allows `eks:DescribeCluster`, SSM session management, and `AmazonSSMManagedInstanceCore`. |

---

## How the Two VPCs Connect

1. **Transit Gateway** is created in the hub. Both VPCs attach via their respective subnets.
2. **Hub → Spoke (bastion to EKS):** Bastion → hub public route (spoke CIDR via TGW) → TGW → spoke attachment → EKS private API endpoint.
3. **Spoke → Hub:** Spoke route tables include hub CIDR and `10.0.0.0/8` via TGW.
4. **Spoke → RDS / Redis / MQ:** Same VPC — no TGW. SGs allow ingress only from the EKS cluster SG.
5. **Spoke → Internet:** Private subnet → NAT (same AZ) → IGW. VPC endpoints bypass NAT for ECR, S3, STS, Secrets Manager.

---

## Additional Modules

### GitHub Actions (terraform/aws/github-actions)

| Resource | Purpose |
|----------|---------|
| **aws_iam_openid_connect_provider.github_actions** | Trusts GitHub's OIDC token endpoint. |
| **aws_iam_role.github_actions** | Assumed by CI via OIDC federation — no static AWS keys anywhere. |
| **aws_iam_policy.ecr** | Push access to all 7 ECR repositories. |

CI assumes this role on every workflow run. The role is valid only for pushes from the configured GitHub repo and branch.

### FinOps (terraform/aws/finops)

| Piece | What it does |
|-------|--------------|
| **Cost allocation tags** | Marks tag keys (`environment`, `project`, `cost-center`, `module`) active in Cost Explorer. |
| **Budgets** | Monthly dev + prod budgets filtered by `environment` tag; email at 80% threshold. |
| **Billing alarm** | SNS + CloudWatch alarm on account `EstimatedCharges`; fires above USD threshold. |
| **Cost Anomaly Detection** | Optional; email when a service spikes unexpectedly. |

FinOps has no dependency from any infra module. Applied last in `spinup.sh` after all tagged resources exist.

---

## Security

### Network and access control

| Where | Control | Purpose |
|-------|---------|---------|
| **Bastion** | SSM Session Manager (primary) — no open ports required. SSH port 22 from `authorized_ssh_cidrs` (fallback only). | All sessions logged to CloudTrail. No key files to manage or lose. |
| **Bastion IAM** | `eks:DescribeCluster`, `ssm:StartSession`, `AmazonSSMManagedInstanceCore`. | Least privilege — can only describe the cluster and start sessions. |
| **EKS API** | Private endpoint only (`endpoint_public_access = false`). Cluster SG: ingress 443 from EKS nodes + hub VPC CIDR. | Internet has no path to the Kubernetes control plane. |
| **EKS nodes** | Node SG: egress all; no ingress from internet. Traffic only between nodes and cluster SG. | Nodes pull images and talk to control plane — no direct exposure. |
| **RDS / Redis / MQ** | Dedicated SG per service; ingress only from EKS cluster SG. | Only cluster workloads can reach data stores. |
| **Lambda webhook** | Private subnets, dedicated SG (HTTPS egress only). API Gateway invokes via Lambda URL — no SG ingress needed. | Webhook is publicly reachable via API GW URL; Lambda itself has no public network path. |
| **WAF** | REGIONAL Web ACL attached to ALB via Kubernetes Ingress annotation. AWS managed rules + rate limit. | Inspects all inbound HTTP/HTTPS before it reaches pods. |

### IRSA (IAM Roles for Service Accounts)

Every pod that needs AWS access uses IRSA — a short-lived JWT (15-minute expiry) issued by the EKS OIDC provider, scoped to exactly one IAM role. No static credentials anywhere in the cluster.

| Service Account | IAM Role | What It Can Do |
|----------------|----------|----------------|
| `kube-system:aws-node` | vpc_cni_irsa | Manage pod ENIs |
| `kube-system:aws-load-balancer-controller` | alb_controller_irsa | Create/manage ALBs |
| `kube-system:ebs-csi-controller-sa` | ebs_csi_irsa | Provision EBS volumes |
| `kube-system:cluster-autoscaler` | cluster_autoscaler_irsa | Scale ASGs |
| `kube-system:external-dns` | external_dns_irsa | Update Route53 records |
| `argocd:argocd-image-updater` | image_updater_irsa | Read ECR image tags |
| `external-secrets:external-secrets` | external_secrets_irsa | Read Secrets Manager + KMS decrypt |

### Secrets and encryption

| Layer | Implementation |
|-------|----------------|
| **Secrets at rest** | Customer-managed KMS key (CMK). Every decrypt → CloudTrail event with key ID, role, timestamp. |
| **Secret paths** | `payflow/{env}/rds`, `payflow/{env}/redis`, `payflow/{env}/rabbitmq`, `payflow/{env}/jwt`. `env` = `var.environment` value (e.g. `dev`). |
| **Secret delivery** | ESO `ClusterSecretStore` reads from Secrets Manager → creates Kubernetes `Secret` objects. No manual `kubectl create secret`. |
| **ECR auth** | ArgoCD Image Updater calls a runtime script (`aws ecr get-login-password`) — token is always fresh, never baked in. |
| **CI credentials** | GitHub Actions assumes `github_actions` IAM role via OIDC — no AWS access keys in GitHub Secrets. |

### Security monitoring

| Tool | What it watches |
|------|----------------|
| **GuardDuty** | Threat detection: unusual API calls, instance compromises, reconnaissance. |
| **CloudTrail** | Every AWS API call: IAM, EKS, KMS decrypts, SSM sessions, ECR pushes. Multi-region. |
| **Security Hub** | Aggregates findings from GuardDuty + Config. CIS and AWS Foundational benchmarks enabled. |
| **AWS Config** | Configuration recorder — detects drift from baseline resource config. |
| **VPC Flow Logs** | IP-level traffic logs from EKS VPC → CloudWatch. |

---

## Summary

| Aspect | Implementation |
|--------|----------------|
| **Pattern** | Hub-and-spoke, one Transit Gateway. |
| **Hub** | Shared TGW + bastion (SSM primary, SSH fallback); routes to spoke via TGW. |
| **Spoke** | EKS private endpoint; nodes in private subnets; SPOT t3.large in dev, ON_DEMAND in prod. |
| **Managed services** | RDS / Redis / MQ in spoke VPC private subnets; reachable only from EKS cluster SG. |
| **Webhook** | API Gateway HTTP v2 → Lambda (private) → ArgoCD NLB. HMAC-SHA256 validated. |
| **Egress** | Per-VPC: hub via IGW; spoke via per-AZ NAT gateways. No centralized egress. |
| **Credentials** | No static keys anywhere. IRSA for pods, OIDC for CI, SSM for bastion access. |
| **Secrets** | KMS CMK → Secrets Manager → ESO → Kubernetes Secrets. Every decrypt audited. |
| **Security posture** | WAF → ALB, GuardDuty, CloudTrail, Security Hub (CIS + AWS Foundational), Config, VPC Flow Logs. |

For a dependency-level view of every resource and Terraform apply order, see [ARCHITECTURE-MAP.md](ARCHITECTURE-MAP.md).
