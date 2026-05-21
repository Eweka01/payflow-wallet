#!/bin/bash
# PayFlow infrastructure spin-up
# Applies all Terraform modules in dependency order:
#   bootstrap → hub-vpc → spoke-vpc-eks → managed-services → bastion → github-actions → finops
# Prints a summary of all values needed for the next steps when complete.
# Run from repo root.
set -euo pipefail
export AWS_PAGER=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Cloud selection ───────────────────────────────────────────────────────────
echo ""
echo "  Deploy to which cloud?"
echo "    aws  — AWS (EKS)"
echo "    aks  — Azure (AKS)"
echo ""
read -p "  Enter aws or aks [aws]: " CLOUD
CLOUD="${CLOUD:-aws}"
if [ "$CLOUD" != "aws" ] && [ "$CLOUD" != "aks" ]; then
  echo "[spinup] ERROR: Use 'aws' or 'aks'. Got: $CLOUD"
  exit 1
fi

# Environment value used in Secrets Manager paths (payflow/dev/*) and resource tags.
# NOT a Terraform workspace — this project always uses the default workspace.
# tfvars files set environment = "dev" in each module.
ENVIRONMENT="dev"
REGION="${AWS_REGION:-us-east-1}"

if [ "$CLOUD" = "aws" ]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
    || { echo "[spinup] AWS CLI not configured. Run: aws configure"; exit 1; }
  TFSTATE_BUCKET="payflow-tfstate-${ACCOUNT}"
fi

unset TF_WORKSPACE
echo "[spinup] Account: $ACCOUNT  Environment: $ENVIRONMENT  Region: $REGION  Workspace: default"

# ── Interrupt handler ─────────────────────────────────────────────────────────
cleanup_on_interrupt() {
  echo ""
  echo "[spinup] Interrupted. If the next run fails with 'Error acquiring the state lock':"
  echo "  cd into the failing module directory, then:"
  echo "  terraform force-unlock <LOCK_ID>  (use the Lock ID from the error message)"
  exit 130
}
trap cleanup_on_interrupt SIGINT SIGTERM

# ── Logging helpers ───────────────────────────────────────────────────────────
log()     { echo "[spinup] $1"; }
warn()    { echo "[spinup] WARN: $1"; }
error()   { echo "[spinup] ERROR: $1" >&2; exit 1; }
banner()  {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ── Bootstrap: S3 state bucket + DynamoDB lock table ─────────────────────────
bootstrap_backend() {
  banner "BOOTSTRAP — S3 State Bucket + DynamoDB Lock Table"

  # S3 bucket
  if ! aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null; then
    log "Creating S3 bucket: $TFSTATE_BUCKET"
    if [ "$REGION" = "us-east-1" ]; then
      # us-east-1 does NOT accept a LocationConstraint — all other regions do
      aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null || true
    else
      aws s3api create-bucket \
        --bucket "$TFSTATE_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || true
    fi
    aws s3api put-bucket-versioning \
      --bucket "$TFSTATE_BUCKET" \
      --versioning-configuration Status=Enabled \
      --region "$REGION" 2>/dev/null || true
    aws s3api put-bucket-encryption \
      --bucket "$TFSTATE_BUCKET" \
      --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
      --region "$REGION" 2>/dev/null || true
    aws s3api put-public-access-block \
      --bucket "$TFSTATE_BUCKET" \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
      --region "$REGION" 2>/dev/null || true
    log "S3 bucket ready: $TFSTATE_BUCKET"
  else
    log "S3 bucket already exists: $TFSTATE_BUCKET"
  fi

  # DynamoDB lock table
  if ! aws dynamodb describe-table --table-name payflow-tfstate-lock --region "$REGION" &>/dev/null; then
    log "Creating DynamoDB table: payflow-tfstate-lock"
    aws dynamodb create-table \
      --table-name payflow-tfstate-lock \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION" 2>/dev/null || true
    log "Waiting for DynamoDB table to become ACTIVE..."
    aws dynamodb wait table-exists --table-name payflow-tfstate-lock --region "$REGION" 2>/dev/null || true
  else
    log "DynamoDB table already exists: payflow-tfstate-lock"
  fi

  # Patch all backend.tf files to use THIS account's bucket and region.
  # This replaces any hardcoded account ID left from a previous developer's run.
  log "Patching backend.tf files → bucket=$TFSTATE_BUCKET  region=$REGION"
  local patched=0
  for backend_file in \
    "$REPO_ROOT/terraform/aws/hub-vpc/backend.tf" \
    "$REPO_ROOT/terraform/aws/spoke-vpc-eks/backend.tf" \
    "$REPO_ROOT/terraform/aws/managed-services/backend.tf" \
    "$REPO_ROOT/terraform/aws/bastion/backend.tf" \
    "$REPO_ROOT/terraform/aws/github-actions/backend.tf" \
    "$REPO_ROOT/terraform/aws/finops/backend.tf"; do
    if [ -f "$backend_file" ]; then
      sed -i.bak "s|bucket[[:space:]]*=[[:space:]]*\"payflow-tfstate-[^\"]*\"|bucket         = \"$TFSTATE_BUCKET\"|g" "$backend_file"
      sed -i.bak "s|^[[:space:]]*region[[:space:]]*=[[:space:]]*\"[^\"]*\"|    region         = \"$REGION\"|" "$backend_file"
      rm -f "${backend_file}.bak"
      log "  Patched: $backend_file"
      patched=$((patched + 1))
    else
      warn "  Not found (skipping): $backend_file"
    fi
  done
  log "Patched $patched backend.tf files."
}

# ── Apply a Terraform module ──────────────────────────────────────────────────
# Usage: apply_module <relative_path> <description> <expected_mins> [extra_var_flags]
apply_module() {
  local module="$1"
  local description="$2"
  local expected_mins="${3:-10}"
  local extra_vars="${4:-}"
  local max_retries=2
  local attempt=0

  banner "TERRAFORM: $description"
  log "Module: $module  (allow ~${expected_mins} min)"
  cd "$REPO_ROOT/$module"

  unset TF_WORKSPACE
  terraform init -input=false -reconfigure

  # Always use the default workspace — spinup.sh never uses named workspaces.
  # var.environment (set in tfvars) controls the env tag and secret paths, not the workspace.
  terraform workspace select default 2>/dev/null || true

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))
    log "Attempt $attempt/$max_retries: $module"

    if (
      terraform plan -input=false -out=/tmp/apply.plan ${extra_vars:+ $extra_vars} \
      && terraform apply -input=false /tmp/apply.plan
    ); then
      cd "$REPO_ROOT"
      log "Done: $module"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      warn "Failed on attempt $attempt — retrying in 30s..."
      sleep 30
    fi
  done

  error "$module failed after $max_retries attempts. See output above."
}

# ── Azure (AKS) path ──────────────────────────────────────────────────────────
spinup_aks() {
  log "Azure (AKS): hub-vnet → spoke-vnet-aks → managed-services → bastion"
  if ! az account show &>/dev/null; then
    error "Azure CLI not logged in. Run: az login"
  fi
  apply_module "terraform/azure/hub-vnet"        "Hub VNet"                          5
  apply_module "terraform/azure/spoke-vnet-aks"  "AKS cluster + ACR"                30
  apply_module "terraform/azure/managed-services" "PostgreSQL, Redis, Service Bus"   20
  apply_module "terraform/azure/bastion"         "Bastion"                            3
  log "AKS spin-up complete."
}

# ── Drift imports: spoke-vpc-eks ──────────────────────────────────────────────
# Imports CloudWatch log group and VPC flow log if they already exist in AWS
# but are missing from Terraform state (prevents ResourceAlreadyExists on re-runs).
import_spoke_drift_if_exists() {
  # Log group name matches vpc-flow-logs.tf: /aws/vpc-flow-logs/<cluster>-<environment>
  local log_group="/aws/vpc-flow-logs/payflow-eks-cluster-${ENVIRONMENT}"

  cd "$REPO_ROOT/terraform/aws/spoke-vpc-eks"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select default 2>/dev/null || true

  if aws logs describe-log-groups \
      --log-group-name-prefix "$log_group" \
      --region "$REGION" \
      --query "logGroups[?logGroupName=='${log_group}'].logGroupName" \
      --output text 2>/dev/null | grep -q .; then
    log "CloudWatch log group exists — importing: $log_group"
    terraform import aws_cloudwatch_log_group.flow_logs "$log_group" 2>/dev/null \
      || log "  Already in state, skipping."
  fi

  local flow_log_id
  flow_log_id=$(aws ec2 describe-flow-logs \
    --filter "Name=log-group-name,Values=${log_group}" \
    --region "$REGION" \
    --query "FlowLogs[0].FlowLogId" \
    --output text 2>/dev/null)
  if [ -n "$flow_log_id" ] && [ "$flow_log_id" != "None" ]; then
    log "VPC flow log exists — importing: $flow_log_id"
    terraform import aws_flow_log.eks "$flow_log_id" 2>/dev/null \
      || log "  Already in state, skipping."
  fi

  cd "$REPO_ROOT"
}

# ── Drift imports: EKS node access entry ─────────────────────────────────────
import_node_access_entry_if_exists() {
  local cluster="payflow-eks-cluster"
  local node_role_arn="arn:aws:iam::${ACCOUNT}:role/payflow-eks-node-role"

  cd "$REPO_ROOT/terraform/aws/spoke-vpc-eks"
  unset TF_WORKSPACE
  terraform workspace select default 2>/dev/null || true

  if aws eks describe-access-entry \
      --cluster-name "$cluster" \
      --principal-arn "$node_role_arn" \
      --region "$REGION" &>/dev/null; then
    log "Node access entry exists — importing to Terraform state..."
    terraform import aws_eks_access_entry.node_role \
      "${cluster}:${node_role_arn}" 2>/dev/null || log "  Already in state, skipping."
  fi
  cd "$REPO_ROOT"
}

# ── Drift imports: bastion IAM role + instance profile ───────────────────────
import_bastion_if_exists() {
  cd "$REPO_ROOT/terraform/aws/bastion"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select default 2>/dev/null || true

  if aws iam get-role --role-name payflow-bastion-role &>/dev/null; then
    log "Bastion IAM role exists — importing..."
    terraform import -input=false aws_iam_role.bastion payflow-bastion-role 2>/dev/null \
      || log "  Already in state, skipping."
  fi
  if aws iam get-instance-profile --instance-profile-name payflow-bastion-profile &>/dev/null; then
    log "Bastion instance profile exists — importing..."
    terraform import -input=false aws_iam_instance_profile.bastion payflow-bastion-profile 2>/dev/null \
      || log "  Already in state, skipping."
  fi
  cd "$REPO_ROOT"
}

# ── Drift imports: GitHub Actions OIDC provider + IAM role ───────────────────
# aws_iam_openid_connect_provider is one-per-URL per account — fails if it already exists.
import_github_actions_if_exists() {
  cd "$REPO_ROOT/terraform/aws/github-actions"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select default 2>/dev/null || true

  local oidc_arn
  oidc_arn=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')].Arn" \
    --output text 2>/dev/null || true)
  if [ -n "$oidc_arn" ] && [ "$oidc_arn" != "None" ]; then
    log "GitHub OIDC provider exists — importing: $oidc_arn"
    terraform import aws_iam_openid_connect_provider.github_actions "$oidc_arn" 2>/dev/null \
      || log "  Already in state, skipping."
  fi

  if aws iam get-role --role-name payflow-github-actions-role &>/dev/null; then
    log "GitHub Actions IAM role exists — importing..."
    terraform import aws_iam_role.github_actions payflow-github-actions-role 2>/dev/null \
      || log "  Already in state, skipping."
  fi

  cd "$REPO_ROOT"
}

# ── Print final summary ───────────────────────────────────────────────────────
print_summary() {
  banner "SPIN-UP COMPLETE — SAVE THESE VALUES"

  local bastion_id ssm_cmd gha_role_arn webhook_url waf_arn acm_arn

  bastion_id=$(terraform -chdir="$REPO_ROOT/terraform/aws/bastion" \
    output -raw bastion_instance_id 2>/dev/null || echo "<check AWS console>")
  ssm_cmd="aws ssm start-session --target $bastion_id --region $REGION"

  gha_role_arn=$(terraform -chdir="$REPO_ROOT/terraform/aws/github-actions" \
    output -raw github_actions_role_arn 2>/dev/null || echo "<check terraform/aws/github-actions>")

  webhook_url=$(terraform -chdir="$REPO_ROOT/terraform/aws/spoke-vpc-eks" \
    output -raw argocd_webhook_url 2>/dev/null || echo "<check terraform/aws/spoke-vpc-eks>")

  waf_arn=$(terraform -chdir="$REPO_ROOT/terraform/aws/spoke-vpc-eks" \
    output -raw waf_web_acl_arn 2>/dev/null || echo "<check terraform/aws/spoke-vpc-eks>")

  acm_arn=$(terraform -chdir="$REPO_ROOT/terraform/aws/spoke-vpc-eks" \
    output -raw acm_certificate_arn 2>/dev/null || echo "")

  echo "  BASTION HOST"
  echo "    Instance ID : $bastion_id"
  echo "    SSM connect : $ssm_cmd"
  echo ""
  echo "  GITHUB ACTIONS  (Settings → Secrets and variables → Actions)"
  echo "    AWS_ROLE_ARN: $gha_role_arn"
  echo "    (also add SNYK_TOKEN and SONAR_TOKEN manually)"
  echo ""
  echo "  ARGOCD WEBHOOK  (needed for Step 17 in deployment guide)"
  echo "    Webhook URL : $webhook_url"
  echo ""
  echo "  HELM VALUES  (paste into helm/payflow/values-dev.yaml → ingress block)"
  echo "    wafArn         : $waf_arn"
  if [ -n "$acm_arn" ] && [ "$acm_arn" != "null" ]; then
    echo "    certificateArn : $acm_arn"
  else
    echo "    certificateArn : (not provisioned — ALB will serve HTTP only)"
  fi
  echo ""

  banner "NEXT STEPS"

  echo "  1. Add GitHub Actions secrets (run from local machine):"
  echo ""
  echo "       gh secret set AWS_ROLE_ARN --body \"$gha_role_arn\""
  echo "       gh secret set SNYK_TOKEN   --body \"<your-snyk-token>\""
  echo "       gh secret set SONAR_TOKEN  --body \"<your-sonar-token>\""
  echo ""
  echo "  2. Update WAF ARN in helm/payflow/values-dev.yaml, then commit + push."
  echo "     This push ALSO triggers the CI pipeline (builds + pushes 7 images to ECR):"
  echo ""
  echo "       (edit ingress.wafArn = the WAF ARN shown above)"
  echo "       git add helm/payflow/values-dev.yaml"
  echo "       git commit -m \"update WAF ARN for current spinup\""
  echo "       git push origin main"
  echo ""
  echo "  3. WAIT for CI to finish — images MUST be in ECR before the next step:"
  echo ""
  echo "       gh run view --watch        # ~7 min"
  echo ""
  echo "     ⚠ REQUIRED ORDER: CI must run BEFORE setup-cluster.sh."
  echo "       setup-cluster Step 6 sets global.imageTag from the latest ECR image."
  echo "       If ECR is empty, the first sync DEADLOCKS — Image Updater cannot"
  echo "       bootstrap the tag from zero running pods (chicken-and-egg)."
  echo ""
  echo "  4. Run setup-cluster.sh from your LOCAL machine (AFTER CI is green):"
  echo ""
  echo "       ./infra-scripts/setup-cluster.sh"
  echo ""
  echo "     Installs: ArgoCD (internal NLB) · ESO · ALB controller · metrics-server · Image Updater"
  echo "     Applies:  ArgoCD Application manifests (payflow + payflow-monitoring)"
  echo "     Sets:     global.imageTag from ECR → first sync deploys all 12 pods cleanly"
  echo "     Prints:   frontend URL · ArgoCD URL · ArgoCD admin password"
  echo ""
  echo "  5. Configure ArgoCD webhook (one-time, after setup-cluster.sh completes):"
  echo "     See Step 17 in Desktop/PayFlow-Docs/full-deployment-guide.txt"
  echo "     Webhook URL: $webhook_url"
  echo ""
  echo "  Full guide: Desktop/PayFlow-Docs/full-deployment-guide.txt"
  echo ""
}

# =============================================================================
# AZURE PATH
# =============================================================================
if [ "$CLOUD" = "aks" ]; then
  spinup_aks
  exit 0
fi

# =============================================================================
# AWS PATH — modules applied in strict dependency order
# =============================================================================

bootstrap_backend

banner "AWS SPIN-UP ORDER"
echo "  bootstrap → hub-vpc → spoke-vpc-eks → managed-services → bastion → github-actions → finops"
echo "  Total estimated time: 60-75 minutes"
echo ""

# ── 1. Hub VPC + Transit Gateway ─────────────────────────────────────────────
# Must be first after bootstrap: spoke-vpc-eks reads TGW ID from hub state.
apply_module "terraform/aws/hub-vpc" \
  "Hub VPC + Transit Gateway" 3

# ── 2. Spoke VPC + EKS + ECR + Lambda webhook ────────────────────────────────
# Needs hub TGW (via hub_tfstate_bucket remote state).
# Creates: EKS cluster, 7 ECR repos, IRSA roles, API Gateway, Lambda, WAF, Secrets Manager secrets.
# Bootstrap EC2 node installs ALB Controller + ArgoCD Image Updater via Helm during apply.
import_spoke_drift_if_exists
apply_module "terraform/aws/spoke-vpc-eks" \
  "Spoke VPC + EKS + ECR + Lambda webhook" 45 \
  "-var=hub_tfstate_bucket=$TFSTATE_BUCKET"
import_node_access_entry_if_exists

# ── 3. Managed services: RDS + ElastiCache Redis + Amazon MQ ─────────────────
# Needs EKS node security group (via tfstate_bucket remote state) to set SG ingress rules.
# null_resource provisioners write real endpoints into Secrets Manager after each resource is up.
apply_module "terraform/aws/managed-services" \
  "RDS PostgreSQL + ElastiCache Redis + Amazon MQ" 25 \
  "-var=tfstate_bucket=$TFSTATE_BUCKET"

# Verify Secrets Manager was populated — fail fast here rather than discovering
# it during ArgoCD sync when ESO throws SecretSyncedError.
banner "VERIFY — Secrets Manager Population"
log "Checking payflow/dev/{rds,redis,rabbitmq} secrets have real values..."
for entry in "rds:host" "redis:url" "rabbitmq:url"; do
  NAME="${entry%%:*}"
  FIELD="${entry##*:}"
  VAL=$(aws secretsmanager get-secret-value \
    --secret-id "payflow/${ENVIRONMENT}/${NAME}" \
    --region "$REGION" --query SecretString --output text 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${FIELD}',''))" 2>/dev/null)
  [ -z "$VAL" ] && error \
    "payflow/${ENVIRONMENT}/${NAME}.${FIELD} is empty — null_resource provisioner failed.\n  Check CloudTrail for the AWS CLI call that should have written it.\n  You can re-run: terraform -chdir=terraform/aws/managed-services apply"
  log "  payflow/${ENVIRONMENT}/${NAME}.${FIELD} = <populated>"
done
log "Secrets Manager population OK"

# ── 4. Bastion host ───────────────────────────────────────────────────────────
# Needs Hub VPC subnet (reads hub state). Provides SSM access to EKS for kubectl.
# No tfstate_bucket var in bastion module — removed to avoid undeclared variable error.
import_bastion_if_exists
apply_module "terraform/aws/bastion" \
  "Bastion host (SSM — no SSH keys)" 3

# ── 5. GitHub Actions OIDC + IAM role ────────────────────────────────────────
# Creates the IAM role CI uses to push images to ECR — no static keys, OIDC only.
# Required before Step 9 (AWS_ROLE_ARN secret) and Step 16 (CI pipeline).
# Scoped to repo: Eweka01/payflow-wallet.
import_github_actions_if_exists
apply_module "terraform/aws/github-actions" \
  "GitHub Actions OIDC + IAM role (keyless CI auth)" 2

# ── 6. FinOps: budgets + anomaly detection + billing alarm ───────────────────
# Must run last — reads remote state from all modules above.
apply_module "terraform/aws/finops" \
  "FinOps (budgets, anomaly detection, billing alarm)" 5 \
  "-var=aws_account_id=$ACCOUNT"

# ── Done — print everything the user needs for the next steps ─────────────────
print_summary
