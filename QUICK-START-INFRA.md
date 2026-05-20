# Quick Start: Get Infrastructure Running

> **Optional detail.** Canonical order and links: [docs/README.md](docs/README.md). Prefer **[docs/INFRASTRUCTURE-ONBOARDING.md](docs/INFRASTRUCTURE-ONBOARDING.md)** for the full story, **[docs/DEPLOYMENT-ORDER.md](docs/DEPLOYMENT-ORDER.md)** for Terraform targets, and **`./spinup.sh`** from the repo root for scripted applies. This file adds extra verification and narrative that **overlaps** those.

This guide walks you through deploying the PayFlow infrastructure step-by-step.

---

## Infrastructure onboarding (right order)

Deploy in this order. Each step depends on the previous.

| # | Step | Directory | Time |
|---|------|-----------|------|
| 1 | Bootstrap (S3 + DynamoDB for state) | `terraform` | ~2 min |
| 2 | Hub VPC (networking foundation) | `terraform/aws/hub-vpc` | ~3 min |
| 3 | EKS (VPC, cluster, addons, nodes — use targets) | `terraform/aws/spoke-vpc-eks` | ~40–50 min |
| 4 | Managed services (RDS, ElastiCache, MQ) | `terraform/aws/managed-services` | ~25–35 min |
| 5 | Bastion (for kubectl; EKS is private) | `terraform/aws/bastion` | ~3 min |
| 6 | Application (K8s manifests) | `k8s/overlays/eks` | ~2 min |

**Critical:** Step 4 requires Step 3 to be applied first (VPC and subnets must exist). For RDS/Redis/MQ to allow traffic from EKS, **do not** hardcode `tfstate_bucket` in `terraform.tfvars`. Pass it at apply time so the module reads EKS security groups from spoke state. From repo root you can use `./spinup.sh`, which passes `-var=tfstate_bucket=payflow-tfstate-<ACCOUNT>` into managed-services automatically.

**Plain English:** For a short explanation of what `spinup.sh` does and a list of infrastructure issues we fixed (Redis TLS, secrets wiring, ESO, CI→ECR, etc.), see **[SPINUP-AND-INFRA-FIXES.md](SPINUP-AND-INFRA-FIXES.md)**.

---

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] **AWS CLI** installed and configured (`aws configure`)
- [ ] **Terraform** >= 1.5.0 installed (`terraform version`)
- [ ] **kubectl** installed (`kubectl version --client`) - Note: Will be used on bastion host
- [ ] **AWS Account** with permissions for: VPC, EKS, RDS, ElastiCache, Secrets Manager, IAM, SSM
- [ ] **SSM Session Manager Plugin** installed (for node access) - Optional but recommended
- [ ] **Docker** installed (for local testing, optional)

**Verify AWS access:**
```bash
aws sts get-caller-identity
# Should show your AWS account ID and user ARN
```

**⚠️ IMPORTANT ARCHITECTURE NOTE:**
- **EKS cluster endpoint is PRIVATE** (`endpoint_public_access = false`)
- **EKS nodes are in PRIVATE subnets** (no direct internet access)
- **Access methods:**
  - **kubectl**: Via Bastion host (SSH to bastion, then use kubectl)
  - **Node access**: Via SSM Session Manager (no SSH keys needed)
  - **Application**: Via ALB/Ingress (public-facing)

---

## Step 1: Spin Up Infrastructure (One Command)

From repo root, run `./spinup.sh`. It creates the S3 bucket, DynamoDB lock table, patches all `backend.tf` files, and applies all Terraform modules in the correct order (Hub → EKS → Managed services → Bastion → FinOps).

```bash
# From repository root
./spinup.sh
```

**What happens:**
- Creates S3 bucket: `payflow-tfstate-{YOUR_ACCOUNT_ID}`
- Creates DynamoDB table: `payflow-tfstate-lock`
- Patches `backend.tf` in all 5 modules (hub, spoke, managed-services, bastion, finops)
- Applies Hub VPC → EKS → Managed services → Bastion → FinOps

**Time:** ~90 minutes (EKS and RDS are the slowest)

**Verify:**
```bash
# Check S3 bucket exists
aws s3 ls | grep payflow-tfstate

# Check DynamoDB table exists
aws dynamodb list-tables | grep payflow-tfstate-lock
```

---

## Step 2: Deploy Hub VPC (Networking Foundation)

The Hub VPC provides shared networking infrastructure.

```bash
cd terraform/aws/hub-vpc
terraform init
terraform workspace new dev
terraform plan
terraform apply
```

**What this creates:**
- Hub VPC
- Transit Gateway
- Public subnet (for bastion)
- Private subnet (for shared services)
- Route tables

**Time:** ~3 minutes

**Verify:**
```bash
terraform output
# Should show: hub_vpc_id, transit_gateway_id
```

---

## Step 3: Deploy EKS Cluster (Use Targets!)

**⚠️ CRITICAL:** Deploy in this exact order using Terraform targets to avoid dependency issues.

```bash
cd terraform/aws/spoke-vpc-eks
terraform init
terraform workspace select dev
terraform plan -out=tfplan
```

### Step 3.1: Networking First

```bash
terraform apply -target=module.networking
```

**Why:** VPC, subnets, NAT Gateway must exist before cluster.

**Time:** ~5 minutes

### Step 3.2: EKS Cluster (without nodes)

```bash
terraform apply -target=aws_eks_cluster.payflow
```

**Why:** Cluster API must exist before addons and nodes.

**Time:** ~15 minutes

### Step 3.3: VPC CNI Addon (Critical!)

```bash
terraform apply -target=aws_eks_addon.vpc_cni
```

**Why:** Pods need IP addresses. CNI must be installed before nodes join.

**Time:** ~2 minutes

**⚠️ IMPORTANT:** EKS cluster has **private endpoint only** (`endpoint_public_access = false`). You cannot access it directly from your local machine. All `kubectl` commands below require **bastion** (or VPN). Deploy bastion (Step 5) first if you want to run verifications; or use SSM for node-level checks only.
- **Bastion host** — for kubectl (required for verification steps)
- **SSM Session Manager** — for node access (no kubectl on nodes)

**Verify CNI is ready (bastion via SSM — deploy bastion first in Step 5):**

```bash
aws ssm start-session --target <bastion-instance-id> --region us-east-1
# On bastion (ubuntu user):
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl get pods -n kube-system -l k8s-app=aws-node
# Wait until all pods are Running
```

**Or check node-level via SSM (no kubectl needed):**
```bash
# List EKS nodes (get instance IDs)
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=payflow-eks-on-demand-nodes" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

# Connect to a node via SSM
aws ssm start-session --target <instance-id>
```

### Step 3.4: SPOT Node Group

```bash
terraform apply -target=aws_eks_node_group.spot
```

**Why:** Dev environment uses SPOT t3.large nodes (desired 2, min 1, max 3). Prod uses ON_DEMAND — change `var.environment` to `prod` for that.

**Time:** ~10 minutes

### Step 3.6: CoreDNS Addon

```bash
terraform apply -target=aws_eks_addon.coredns
```

**Why:** DNS resolution needed for services. Requires nodes to be ready.

**Time:** ~2 minutes

### Step 3.7: Everything Else

```bash
terraform apply
```

**What this applies:**
- Remaining addons (kube-proxy, etc.)
- IRSA roles
- Secrets Manager secrets
- Route from Hub to EKS

**Time:** ~5 minutes

**Verify cluster is ready (bastion via SSM):**

```bash
aws ssm start-session --target <bastion-instance-id> --region us-east-1
# On bastion:
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl cluster-info
kubectl get nodes
# Should show all nodes Ready
```

---

## Step 4: Deploy Managed Services (RDS, ElastiCache, MQ)

**Prerequisites:**
- Step 3 (EKS/spoke-vpc-eks) must be applied so the VPC `payflow-eks-vpc` and private subnets exist.
- To allow RDS, ElastiCache, and MQ to accept traffic from EKS nodes, do **one** of:
  - **Option A (recommended):** Set `tfstate_bucket` to your Terraform state bucket (same as EKS) and use the **same workspace** (e.g. `dev`). The module will read the EKS cluster security group from spoke state.
  - **Option B:** After EKS is up, get the EKS node security group ID and pass it: `-var="eks_node_security_group_id=sg-xxxxx"`.

**⚠️ IMPORTANT:** You must provide `db_password` and `rabbitmq_password` (no defaults; use strong passwords).

```bash
cd terraform/aws/managed-services
terraform init
terraform workspace select dev   # must match spoke-vpc-eks workspace

# Optional: use tfvars so EKS SG is wired from spoke state (replace ACCOUNT_ID)
echo 'tfstate_bucket = "payflow-tfstate-ACCOUNT_ID"' >> terraform.tfvars

terraform validate
terraform plan -out=tfplan

# Apply (you will be prompted for db_password and rabbitmq_password)
terraform apply
# Or with vars: terraform apply -var="db_password=YOUR_DB_PASS" -var="rabbitmq_password=YOUR_MQ_PASS"
```

**When prompted, enter:**
- `db_password`: Strong password for PostgreSQL (e.g. `openssl rand -base64 32`)
- `rabbitmq_password`: Strong password for RabbitMQ (e.g. `openssl rand -base64 32`)

**What this creates:**
- **RDS PostgreSQL** — uses default engine version for major version (e.g. 16). Creation typically **15–20+ minutes** (longer if Multi-AZ in prod).
- **ElastiCache Redis** — typically **~8–10 minutes**.
- **Amazon MQ (RabbitMQ 3.13)** — typically **~15 minutes**.
- **Secrets** in AWS Secrets Manager (RDS and RabbitMQ endpoints are written by `null_resource` after creation).

**Time:** ~25–35 minutes (RDS is the bottleneck).

**Key variables (defaults are set):**
- `postgres_version`: Major version only, e.g. `"16"` or `"15"` (default `"16"`). Uses AWS default engine version for that major.
- `rabbitmq_version`: `"3.13"` (Amazon MQ valid values: 3.13, 4.2).
- `snapshot_window` (ElastiCache) and `maintenance_window` must not overlap; defaults are set to avoid overlap.

**Verify:**
```bash
terraform output
# Should show: rds_endpoint, rds_address, redis_endpoint, mq_amqp_endpoint, mq_management_endpoint

# Check secrets exist
aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'payflow')]"
```

---

## Step 5: Deploy Bastion (Required for kubectl Access)

**⚠️ REQUIRED:** Bastion host is your **only way to access the EKS cluster** via kubectl since the cluster endpoint is private.

```bash
cd terraform/aws/bastion
terraform init
terraform workspace select dev
terraform apply
```

**What this creates:**
- EC2 instance in Hub public subnet
- Security group (SSH from authorized IPs; egress for EKS + SSM)
- IAM role with EKS access + **AmazonSSMManagedInstanceCore** (Session Manager)
- Route from bastion to EKS (via Transit Gateway)

**Time:** ~3 minutes

**After deployment — connect via SSM (recommended, no SSH key):**
```bash
cd terraform/aws/bastion
terraform output ssm_connect_command
# Run the printed command, e.g.:
aws ssm start-session --target i-xxxxx --region us-east-1

# Once on the bastion, configure kubectl
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl get nodes
```

**Bastion access is SSM-only — no SSH keys, no open port 22 required.** All sessions are logged to CloudTrail automatically.

**Optional SSH over SSM** (if you need SCP or local port-forwarding via SSH):
```sshconfig
Host payflow-bastion-ssm
  HostName <bastion-instance-id>
  User ubuntu
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```
Then: `ssh payflow-bastion-ssm` (requires Session Manager plugin installed locally).

**Note:** For EKS node access (no kubectl on nodes), use `aws ssm start-session --target <node-instance-id>` (see Step 3.3).

---

## Step 6: Run setup-cluster.sh

This script runs **from your local machine** after `spinup.sh` completes. It uses SSM Run Command to install ArgoCD, ESO, ALB Controller, ArgoCD Image Updater, and apply both ArgoCD Application manifests — no SSH keys or bastion login required.

```bash
# From repo root
./infra-scripts/setup-cluster.sh
```

**Flags:**
- `--skip-argocd` — skip ArgoCD install (already installed)
- `--skip-eso` — skip ESO install (already installed)

**What it does:**
1. Verifies EKS cluster is ACTIVE and bastion SSM is Online
2. Configures kubeconfig on the bastion
3. Installs ArgoCD and patches the service to an internal NLB (VPC-only)
4. Patches `argocd-cm` with PVC health Lua override (prevents Pending PVCs from blocking sync)
5. Installs External Secrets Operator with IRSA annotation
6. Installs AWS Load Balancer Controller + metrics-server
7. Installs ArgoCD Image Updater with ECR credentials volume
8. Applies `helm/argocd/application.yaml` and `helm/argocd/monitoring-application.yaml`
9. Patches `global.imageTag` to the latest ECR tag so ArgoCD never pulls `:latest`
10. Waits up to 10 minutes for the `payflow` app to become Healthy

**Time:** ~10–15 minutes

**When it completes, the output shows:**
```
  ArgoCD NLB (VPC-only):  https://<nlb-hostname>
  ArgoCD admin password:  <password>
```

Save both — you need them in the post-setup steps below.

**Verify deployment (via bastion — SSM only, no SSH key):**

```bash
# Connect to bastion
aws ssm start-session --target <bastion-instance-id> --region us-east-1

# Configure kubectl (on bastion)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Check pods
kubectl get pods -n payflow
kubectl get pods -n argocd

kubectl get svc -n payflow
kubectl get ingress -n payflow
kubectl logs -n payflow deployment/api-gateway --tail=30
```

---

## Post-Setup Steps (required after setup-cluster.sh)

These steps must be completed after `setup-cluster.sh` finishes. The app will not function correctly without them.

### Step A — Update WAF ARN in values-dev.yaml

The WAF ARN is unique per spinup. Get the current value and commit it:

```bash
# Get the current WAF ARN (run from repo root, workspace must be dev)
cd terraform/aws/spoke-vpc-eks
terraform workspace select dev
terraform output -raw waf_web_acl_arn
```

Edit [helm/payflow/values-dev.yaml](helm/payflow/values-dev.yaml) — update the `ingress.wafArn` field with the output value, then:

```bash
git add helm/payflow/values-dev.yaml
git commit -m "update WAF ARN for current spinup"
git push
```

ArgoCD will auto-sync the ingress within ~3 minutes.

### Step B — Webhook: generate secret and store in Secrets Manager

Run these from the **bastion** (SSM session):

```bash
aws ssm start-session --target <bastion-instance-id> --region us-east-1
```

On the bastion:

```bash
# Generate a new webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Your webhook secret: $WEBHOOK_SECRET"
# Save this value — you need it in Step C

# Store in Secrets Manager
aws secretsmanager update-secret \
  --secret-id "payflow/dev/github-webhook-secret" \
  --secret-string "$WEBHOOK_SECRET" \
  --region us-east-1
```

### Step C — Register the GitHub webhook

Get the webhook URL first:

```bash
# From your local machine
cd terraform/aws/spoke-vpc-eks
terraform output -raw argocd_webhook_url
```

Then register the webhook (replace placeholders):

```bash
gh api repos/Eweka01/payflow-wallet/hooks \
  -f name=web \
  -f "config[url]=<WEBHOOK_URL_FROM_ABOVE>/webhook" \
  -f "config[content_type]=json" \
  -f "config[secret]=<WEBHOOK_SECRET_FROM_STEP_B>" \
  -f "events[]=push" \
  -F "active=true"
```

**Important:** The API Gateway URL changes every spinup. Check if a webhook already exists first:
```bash
gh api repos/Eweka01/payflow-wallet/hooks --jq '.[].config.url'
```
If there's an old Lambda URL, delete it: `gh api repos/Eweka01/payflow-wallet/hooks/<id> -X DELETE`

### Step D — ArgoCD token (enables Lambda → ArgoCD sync)

On the **bastion**, open an SSM port-forward to the ArgoCD NLB:

```bash
# Local machine — get the NLB hostname first
aws ssm start-session --target <bastion-instance-id> --region us-east-1
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Copy the hostname, then exit
exit
```

Then from your local machine, open the tunnel:

```bash
aws ssm start-session \
  --target <bastion-instance-id> \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"<ARGOCD_NLB_HOSTNAME>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8080\"]}"
```

Open `https://localhost:8080` in your browser. Login as `admin` with the password from `setup-cluster.sh` output.

**Enable apiKey capability and generate token:**

```bash
# On the bastion
aws ssm start-session --target <bastion-instance-id> --region us-east-1
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"accounts.admin":"login,apiKey"}}'
```

Then in the ArgoCD UI: **Settings → Accounts → admin → Generate New Token**. Copy the token.

**Store token and NLB URL in Secrets Manager (from bastion):**

```bash
aws secretsmanager update-secret \
  --secret-id "payflow/dev/argocd-token" \
  --secret-string "<YOUR_ARGOCD_TOKEN>" \
  --region us-east-1

aws secretsmanager update-secret \
  --secret-id "payflow/dev/argocd-internal-url" \
  --secret-string "https://<ARGOCD_NLB_HOSTNAME>" \
  --region us-east-1
```

**Verify the full webhook chain:** Make a small change, push to main, and confirm the webhook delivers a 200 and ArgoCD syncs within 30 seconds.

---

## Access Your Application

The ALB URL is public-facing — access it directly from your browser:

```bash
# Get the ALB URL (from bastion)
kubectl get ingress -n payflow
# Or:
kubectl get svc -n payflow -l app=frontend
```

---

## Troubleshooting

### Issue: "Error: Resource depends on resource that doesn't exist"
**Solution:** You skipped a target. Go back and apply the missing resource in order.

### Issue: "Error: VPC CNI pods not starting"
**Solution:** Wait for EKS cluster to be fully ready (all control plane components), then apply CNI addon.

### Issue: "Error: Nodes not joining cluster"
**Solution:** Check that VPC CNI addon is installed and running (via bastion SSM):
```bash
aws ssm start-session --target <bastion-instance-id> --region us-east-1
# On bastion:
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl get pods -n kube-system -l k8s-app=aws-node
```

**Or verify nodes directly via SSM:**
```bash
# Get node instance ID
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table

# Connect to node
aws ssm start-session --target <instance-id>

# Check kubelet status
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100
```

### Issue: "Image tag 'latest' already exists... cannot be overwritten because the tag is immutable"
**Solution:** ECR tags are immutable. CI pushes with a timestamped SHA tag — never `:latest`. If you see this, the CI pipeline is trying to overwrite a tag. Check the ci.yml `prepare` job; it generates a unique tag like `20260519020105-abc1234`.

### Issue: "Error: ImagePullBackOff"
**Solution:** The image tag in `global.imageTag` doesn't exist in ECR. Check Image Updater logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50`.

### Issue: "Error: Null value found in list" (managed-services security groups)
**Solution:** RDS/ElastiCache/MQ security groups need the EKS node security group ID. Set **one** of:
- `tfstate_bucket = "payflow-tfstate-ACCOUNT_ID"` (same bucket and workspace as EKS) so the module reads it from spoke state, or
- `-var="eks_node_security_group_id=sg-xxxxx"` (get the SG from EKS node group or cluster in AWS console).

### Issue: "Error: Cannot find version X.Y for postgres" or "multiple RDS engine versions"
**Solution:** The managed-services module uses the `aws_rds_engine_version` data source with `default_only = true`. Ensure `postgres_version` is a **major version** only (e.g. `"16"` or `"15"`). Override if needed: `-var="postgres_version=15"`.

### Issue: "Error: Cannot connect to RDS"
**Solution:** 
1. Verify RDS endpoint from Terraform output
2. Check security group allows traffic from EKS nodes (requires `tfstate_bucket` or `eks_node_security_group_id` to be set)
3. Verify Secrets Manager has correct credentials:
```bash
aws secretsmanager get-secret-value --secret-id payflow/dev/rds
```

### Issue: Pods in CrashLoopBackOff (api-gateway, auth-service, wallet-service, etc.)
**Diagnose on bastion** — get the real error from a crashing pod:
```bash
# From bastion (SSH or SSM)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Logs from one failing deployment (pick the one that’s crashing)
kubectl logs -n payflow deployment/api-gateway --tail=80
kubectl logs -n payflow deployment/auth-service --tail=80
```

**Common causes and fixes:**

| Symptom in logs | Cause | Fix |
|-----------------|--------|-----|
| `Cannot find module '../shared/metrics'` | Image built without `shared/` | Rebuild images with context `./services` and redeploy with a new tag (see Step 6 and ECR troubleshooting above). |
| `ECONNREFUSED` to Redis or RDS host | EKS nodes can’t reach Redis/RDS | RDS/Redis SGs must allow EKS **node** SG. See [RDS-CONNECTIVITY.md](terraform/aws/managed-services/RDS-CONNECTIVITY.md); re-apply managed-services with same workspace as spoke or `-var="eks_node_sg_id=sg-xxx"`. |
| `transactions_total already registered` (api-gateway crash) | Duplicate Prometheus metric in same process | Fixed in `services/shared/metrics.js` (getSingleMetric). Rebuild api-gateway image and redeploy. |
| `InvalidProviderConfig` / no EC2 IMDS role for External Secrets | External Secrets SA not bound to IRSA role | See [External Secrets IRSA](#external-secrets-irsa-required-once) below. |
| `RABBITMQ_URL` empty / connection failed | Secret not synced or Amazon MQ URL missing | Ensure `payflow/dev/rabbitmq` in Secrets Manager has key `url` (managed-services `null_resource` updates it). On bastion: `kubectl get externalsecret -n payflow` and `kubectl get secret db-secrets -n payflow -o yaml` to confirm keys. |
| DB auth / password error | Wrong credentials in secret | Verify `payflow/dev/rds` in Secrets Manager; re-sync: delete `db-secrets` in payflow and let ESO recreate it. |

After fixing, restart rollouts:
```bash
kubectl rollout restart deployment -n payflow
kubectl get pods -n payflow -w
```

### External Secrets IRSA (verify first; manual only if missing)

The External Secrets ServiceAccount must have `eks.amazonaws.com/role-arn` set so ESO can read Secrets Manager. It is **set automatically** in two cases:

1. **Terraform bootstrap-node** — When the cluster is created, the bootstrap instance installs ESO via Helm with `--set serviceAccount.annotations.eks.amazonaws.com/role-arn=$EXTERNAL_SECRETS_IRSA_ARN`.
2. **setup-cluster.sh** — The bastion script installs ESO with `--set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<IRSA_ARN>` so the annotation is always applied.

**Verify** (on bastion):
```bash
kubectl get sa external-secrets -n external-secrets -o yaml | grep eks.amazonaws.com/role-arn
```
If you see a line like `eks.amazonaws.com/role-arn: arn:aws:iam::...`, no manual step is needed.

**Only if the annotation is missing** (e.g. ESO was installed manually without it), annotate and restart:
```bash
cd terraform/aws/spoke-vpc-eks
ARN=$(terraform output -raw external_secrets_irsa_arn)
# On bastion:
kubectl annotate serviceaccount external-secrets -n external-secrets \
  eks.amazonaws.com/role-arn="$ARN" --overwrite
kubectl rollout restart deployment external-secrets -n external-secrets
```

### Issue: Pods stuck in Pending
**Solution:**
```bash
# Check pod events
kubectl describe pod <pod-name> -n payflow

# Check node resources
kubectl describe nodes

# Check if nodes have capacity
kubectl top nodes
```

---

## Time Estimates

| Phase | Time | Notes |
|-------|------|-------|
| spinup.sh | ~90 min | Hub VPC + EKS + Managed services + Bastion + FinOps |
| setup-cluster.sh | ~15 min | ArgoCD + ESO + ALB Controller + Image Updater |
| Post-setup (Steps A–D) | ~10 min | WAF ARN, webhook, ArgoCD token |
| **Total** | **~115 min** | First deployment |

Subsequent deployments (teardown + respinup): same time. setup-cluster.sh with `--skip-argocd --skip-eso` saves ~5 min if those are already installed.

---

## Next Steps

- ✅ Infrastructure is running!
- Complete **Post-Setup Steps A–D** above if not done
- ArgoCD auto-syncs on every push to `main` via Lambda webhook
- ArgoCD Image Updater polls ECR every 2 minutes and updates `global.imageTag` automatically

---

## Quick Reference Commands

**All kubectl commands run from bastion via SSM — no SSH keys.**

### Access via Bastion (SSM)

```bash
# Connect to bastion
aws ssm start-session --target <bastion-instance-id> --region us-east-1

# Configure kubectl (on bastion, ubuntu user)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Check cluster status
kubectl cluster-info
kubectl get nodes

# Check application status
kubectl get pods -n payflow
kubectl get svc -n payflow
kubectl get ingress -n payflow

# View logs
kubectl logs -n payflow deployment/api-gateway -f

# Port forward for testing
kubectl port-forward -n payflow svc/api-gateway 3000:3000
kubectl port-forward -n payflow svc/frontend 80:80
```

### Access EKS Nodes via SSM

```bash
# List all EKS nodes
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

# Connect to a node directly (for node-level debug — no kubectl here)
aws ssm start-session --target <node-instance-id> --region us-east-1
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100
```

### ArgoCD (VPC-only NLB — SSM tunnel required)

```bash
# Open tunnel from local machine
aws ssm start-session \
  --target <bastion-instance-id> \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"<ARGOCD_NLB_HOSTNAME>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8080\"]}"
# Browser: https://localhost:8080  (admin / <password from setup-cluster.sh output>)
```

### Grafana (VPC-only — SSM tunnel required)

```bash
aws ssm start-session \
  --target <bastion-instance-id> \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"<GRAFANA_SVC_DNS>\"],\"portNumber\":[\"80\"],\"localPortNumber\":[\"3000\"]}"
# Browser: http://localhost:3000  (admin / prom-operator)
```

### Terraform Commands

```bash
# Key outputs
cd terraform/aws/spoke-vpc-eks && terraform workspace select dev
terraform output -raw waf_web_acl_arn
terraform output -raw argocd_webhook_url

cd terraform/aws/bastion && terraform workspace select dev
terraform output ssm_connect_command
```

