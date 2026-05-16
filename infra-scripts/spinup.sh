#!/bin/bash
# PayFlow infrastructure spin-up: backend, hub, EKS/AKS spoke, managed services, bastion, FinOps.
# Run from repo root. Prompts for AWS (EKS) or Azure (AKS). Uses the Terraform default workspace.
# For a plain-English explanation and list of issues we fixed, see SPINUP-AND-INFRA-FIXES.md.
set -euo pipefail

# Prevent AWS CLI from using a pager (e.g. less) so script doesn't appear stuck on create-table etc.
export AWS_PAGER=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Choose cloud: AWS (EKS) or Azure (AKS) ---
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

# Environment tag used in Secrets Manager paths (payflow/dev/*) — not a Terraform workspace.
# This project uses a single Terraform default workspace; tfvars files handle env differences.
ENVIRONMENT="dev"

REGION="${AWS_REGION:-us-east-1}"

if [ "$CLOUD" = "aws" ]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) || { echo "[spinup] AWS CLI not configured"; exit 1; }
  TFSTATE_BUCKET="payflow-tfstate-${ACCOUNT}"
fi

unset TF_WORKSPACE
echo "[spinup] Environment: $ENVIRONMENT  region: $REGION  (using Terraform default workspace)"

# On interrupt, remind how to fix a stuck state lock
cleanup_on_interrupt() {
  echo ""
  echo "[spinup] Interrupted. If the next run fails with 'Error acquiring the state lock',"
  echo "  run in the failing module (e.g. terraform/aws/hub-vpc):"
  echo "  terraform force-unlock <LOCK_ID>"
  echo "  (Use the Lock ID from the error message.)"
  exit 130
}
trap cleanup_on_interrupt SIGINT SIGTERM

log()   { echo "[spinup] $1"; }
warn()  { echo "[spinup] WARN: $1"; }
error() { echo "[spinup] ERROR: $1" >&2; exit 1; }

# --- Backend: S3 bucket + DynamoDB lock table ---
bootstrap_backend() {
  log "Ensuring Terraform backend (S3 + DynamoDB)..."

  # Create S3 bucket if it doesn't exist
  if ! aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null; then
    log "Creating S3 bucket: $TFSTATE_BUCKET"
    # us-east-1 does NOT accept LocationConstraint — all other regions do
    if [ "$REGION" = "us-east-1" ]; then
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

  # Create DynamoDB lock table if it doesn't exist
  if ! aws dynamodb describe-table --table-name payflow-tfstate-lock --region "$REGION" &>/dev/null; then
    log "Creating DynamoDB table: payflow-tfstate-lock"
    aws dynamodb create-table \
      --table-name payflow-tfstate-lock \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION" 2>/dev/null || true
    log "Waiting for DynamoDB table to be active..."
    aws dynamodb wait table-exists --table-name payflow-tfstate-lock --region "$REGION" 2>/dev/null || true
  else
    log "DynamoDB table already exists: payflow-tfstate-lock"
  fi

  # Patch all backend.tf files to use THIS account's bucket and region.
  # This replaces any previously hardcoded account ID (e.g. from another developer's run).
  log "Patching backend.tf files: bucket=$TFSTATE_BUCKET region=$REGION"
  local patched=0
  for backend_file in \
    "$REPO_ROOT/terraform/aws/hub-vpc/backend.tf" \
    "$REPO_ROOT/terraform/aws/spoke-vpc-eks/backend.tf" \
    "$REPO_ROOT/terraform/aws/managed-services/backend.tf" \
    "$REPO_ROOT/terraform/aws/bastion/backend.tf" \
    "$REPO_ROOT/terraform/aws/finops/backend.tf"; do
    if [ -f "$backend_file" ]; then
      # Replace any payflow-tfstate-<anything> bucket name with the correct one (portable sed)
      sed -i.bak "s|bucket[[:space:]]*=[[:space:]]*\"payflow-tfstate-[^\"]*\"|bucket         = \"$TFSTATE_BUCKET\"|g" "$backend_file"
      # Replace region line (portable: no range /start/,/end/ so BSD sed on macOS works)
      sed -i.bak "s|^[[:space:]]*region[[:space:]]*=[[:space:]]*\"[^\"]*\"|    region         = \"$REGION\"|" "$backend_file"
      rm -f "${backend_file}.bak"
      log "  Patched: $backend_file"
      patched=$((patched + 1))
    else
      warn "  Not found (skipping): $backend_file"
    fi
  done
  log "Patched $patched backend.tf files."
  log "Backend ready: $TFSTATE_BUCKET"
}

# --- Apply a Terraform module with optional extra vars ---
# Usage: apply_module <relative_path> <description> <expected_mins> [extra_vars]
# Example: apply_module "terraform/aws/managed-services" "RDS, Redis, MQ" 25 "-var=tfstate_bucket=$TFSTATE_BUCKET"
apply_module() {
  local module="$1"
  local description="$2"
  local expected_mins="${3:-10}"
  local extra_vars="${4:-}"
  local max_retries=2
  local attempt=0

  log "Applying $module — $description (allow ~${expected_mins} min)..."
  cd "$REPO_ROOT/$module"

  unset TF_WORKSPACE
  terraform init -input=false -reconfigure

  # Always use the default workspace — no named workspaces.
  # State is stored directly at the key path in backend.tf (e.g. aws/hub-vpc/terraform.tfstate).
  terraform workspace select default 2>/dev/null || true

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))
    log "Attempt $attempt/$max_retries: $module"

    if (
      terraform plan -input=false -out=/tmp/apply.plan \
        ${extra_vars:+ $extra_vars} \
      && terraform apply -input=false /tmp/apply.plan
    ); then
      cd "$REPO_ROOT"
      log "Done: $module"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      warn "$module failed on attempt $attempt. Retrying in 30s..."
      sleep 30
    fi
  done

  error "$module failed after $max_retries attempts. See output above."
}

# --- Azure (AKS) spin-up: Hub VNet → AKS + ACR → Managed services → Bastion ---
spinup_aks() {
  log "Azure (AKS) spin-up: hub-vnet → spoke-vnet-aks (AKS + ACR) → managed-services → bastion"
  if ! az account show &>/dev/null; then
    error "Azure CLI not logged in. Run: az login"
  fi
  apply_module "terraform/azure/hub-vnet" "Hub VNet" 5
  apply_module "terraform/azure/spoke-vnet-aks" "AKS cluster + ACR" 30
  apply_module "terraform/azure/managed-services" "PostgreSQL, Redis, Service Bus" 20
  apply_module "terraform/azure/bastion" "Bastion" 3
  log "AKS spin-up complete. Run k8s/overlays/aks deploy or aks-deploy.sh to deploy the app."
}

# Auto-import spoke-vpc-eks resources that may already exist in AWS but not in Terraform state.
# Prevents ResourceAlreadyExistsException on re-runs (e.g. CloudWatch log group, flow log).
import_spoke_drift_if_exists() {
  local cluster="payflow-eks-cluster-${ENVIRONMENT}"

  cd "$REPO_ROOT/terraform/aws/spoke-vpc-eks"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select default 2>/dev/null || true

  # CloudWatch log group for VPC flow logs
  local log_group="/aws/vpc-flow-logs/${cluster}"
  if aws logs describe-log-groups \
      --log-group-name-prefix "$log_group" \
      --region "$REGION" \
      --query "logGroups[?logGroupName=='${log_group}'].logGroupName" \
      --output text 2>/dev/null | grep -q .; then
    log "CloudWatch log group already exists — importing to Terraform state: $log_group"
    terraform import \
      aws_cloudwatch_log_group.flow_logs \
      "$log_group" 2>/dev/null || log "  Already in state, skipping."
  fi

  # VPC flow log — look up by log group name and import if found
  local flow_log_id
  flow_log_id=$(aws ec2 describe-flow-logs \
    --filter "Name=log-group-name,Values=${log_group}" \
    --region "$REGION" \
    --query "FlowLogs[0].FlowLogId" \
    --output text 2>/dev/null)
  if [ -n "$flow_log_id" ] && [ "$flow_log_id" != "None" ]; then
    log "VPC flow log already exists — importing to Terraform state: $flow_log_id"
    terraform import \
      aws_flow_log.eks \
      "$flow_log_id" 2>/dev/null || log "  Already in state, skipping."
  fi

  cd "$REPO_ROOT"
}

# Auto-import the node access entry if EKS already created it.
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
    log "Node access entry already exists in EKS — importing to Terraform state..."
    terraform import \
      aws_eks_access_entry.node_role \
      "${cluster}:${node_role_arn}" 2>/dev/null || log "Already in state, skipping import."
  fi
  cd "$REPO_ROOT"
}

# Auto-import bastion IAM role and instance profile if they already exist (avoids 409 on re-run).
import_bastion_if_exists() {
  cd "$REPO_ROOT/terraform/aws/bastion"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select default 2>/dev/null || true

  if aws iam get-role --role-name payflow-bastion-role &>/dev/null; then
    log "Bastion IAM role already exists — importing to Terraform state..."
    terraform import -input=false aws_iam_role.bastion payflow-bastion-role 2>/dev/null || log "  Role already in state, skipping."
  fi
  if aws iam get-instance-profile --instance-profile-name payflow-bastion-profile &>/dev/null; then
    log "Bastion instance profile already exists — importing to Terraform state..."
    terraform import -input=false aws_iam_instance_profile.bastion payflow-bastion-profile 2>/dev/null || log "  Profile already in state, skipping."
  fi
  cd "$REPO_ROOT"
}

if [ "$CLOUD" = "aks" ]; then
  spinup_aks
  exit 0
fi

# --- AWS (EKS) path: bootstrap backend then apply modules in order ---
bootstrap_backend

log "Using default workspace  region: $REGION  bucket: $TFSTATE_BUCKET"

# 1) Hub VPC
apply_module "terraform/aws/hub-vpc" "Hub VPC, TGW" 3

# 2) EKS spoke (VPC, cluster, addons, nodes — use targets per QUICK-START if needed)
# Import any drifted resources (e.g. CloudWatch log group, flow log) before applying
import_spoke_drift_if_exists
apply_module "terraform/aws/spoke-vpc-eks" "EKS VPC, cluster, addons, nodes" 45 \
  "-var=hub_tfstate_bucket=$TFSTATE_BUCKET"
import_node_access_entry_if_exists

# 3) Managed services — pass tfstate_bucket so SGs allow EKS traffic
apply_module "terraform/aws/managed-services" "RDS, ElastiCache, Amazon MQ" 25 "-var=tfstate_bucket=$TFSTATE_BUCKET"

# Verify null_resource updaters wrote endpoints into Secrets Manager (fail fast before deploy.sh)
log "Verifying Secrets Manager population (rds host, redis url, rabbitmq url)..."
for entry in "rds:host" "redis:url" "rabbitmq:url"; do
  NAME="${entry%%:*}"
  FIELD="${entry##*:}"
  VAL=$(aws secretsmanager get-secret-value \
    --secret-id "payflow/${ENVIRONMENT}/${NAME}" \
    --region "$REGION" --query SecretString --output text 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${FIELD}',''))" 2>/dev/null)
  [ -z "$VAL" ] && error "payflow/${ENVIRONMENT}/${NAME}.${FIELD} is empty — null_resource failed. Check CloudTrail/CloudWatch."
  log "  payflow/${ENVIRONMENT}/${NAME}.${FIELD} = <populated>"
done
log "Secrets Manager population OK"

# 4) Bastion (import existing role/profile if present so apply does not 409)
import_bastion_if_exists
apply_module "terraform/aws/bastion" "Bastion host" 3 "-var=tfstate_bucket=$TFSTATE_BUCKET"

# 5) FinOps (budgets, anomaly detection, billing alarm) — must run last: the report module
#    (terraform/finops) reads remote state from hub, spoke, managed-services, bastion; if you add
#    that module to this script it would need to run after all of the above.
apply_module "terraform/aws/finops" "FinOps (budgets, anomaly detection, billing alarm)" 5 \
  "-var=aws_account_id=$ACCOUNT"

log "Spin-up complete. Run k8s/overlays/eks/deploy.sh to deploy the app."
