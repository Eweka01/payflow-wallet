#!/bin/bash
# PayFlow infrastructure teardown — destroys all Terraform-managed resources.
# Run from repo root. Uses same cloud/workspace as spinup (dev or prod).
# Destroy order is reverse of spinup: FinOps → Bastion → Managed services → EKS → Hub VPC.
#
# Usage: ./teardown.sh
#        ENVIRONMENT=prod ./teardown.sh
# To also delete the Terraform backend (S3 bucket + DynamoDB lock table):
#        DESTROY_BACKEND=1 ./teardown.sh
#
# After teardown, run ./spinup.sh to create everything again from scratch.
set -euo pipefail

export AWS_PAGER=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Choose cloud ---
echo ""
echo "  Destroy resources in which cloud?"
echo "    aws  — AWS (EKS)"
echo "    aks  — Azure (AKS)"
echo ""
read -p "  Enter aws or aks [aws]: " CLOUD
CLOUD="${CLOUD:-aws}"
if [ "$CLOUD" != "aws" ] && [ "$CLOUD" != "aks" ]; then
  echo "[teardown] ERROR: Use 'aws' or 'aks'. Got: $CLOUD"
  exit 1
fi

# --- Choose workspace ---
echo ""
echo "  Which Terraform workspace (environment) to destroy?"
echo "    dev   — development"
echo "    prod  — production"
echo "  (No default — you must type dev or prod to avoid destroying wrong env)"
echo ""
read -p "  Enter dev or prod: " ENVIRONMENT
if [ -z "$ENVIRONMENT" ]; then
  echo "[teardown] ERROR: You must enter 'dev' or 'prod' explicitly."
  exit 1
fi
if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "prod" ]; then
  echo "[teardown] ERROR: Use 'dev' or 'prod'. Got: $ENVIRONMENT"
  exit 1
fi

REGION="${AWS_REGION:-us-east-1}"
unset TF_WORKSPACE

if [ "$CLOUD" = "aws" ]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) || { echo "[teardown] AWS CLI not configured"; exit 1; }
  TFSTATE_BUCKET="payflow-tfstate-${ACCOUNT}"
fi

log()   { echo "[teardown] $1"; }
warn()  { echo "[teardown] WARN: $1"; }
error() { echo "[teardown] ERROR: $1" >&2; exit 1; }

cleanup_on_interrupt() {
  echo ""
  echo "[teardown] Interrupted. If the next run fails with 'Error acquiring the state lock',"
  echo "  run in the failing module: terraform force-unlock <LOCK_ID>"
  exit 130
}
trap cleanup_on_interrupt SIGINT SIGTERM

# --- Destroy a Terraform module ---
# Usage: destroy_module <relative_path> <description> [extra_vars] [no_refresh]
# If 4th arg is "no_refresh", pass -refresh=false (skips slow AWS Budgets API refresh).
destroy_module() {
  local module="$1"
  local description="$2"
  local extra_vars="${3:-}"
  local refresh_opt=""
  [ "${4:-}" = "no_refresh" ] && refresh_opt="-refresh=false"

  log "Destroying $module — $description..."
  cd "$REPO_ROOT/$module"
  unset TF_WORKSPACE
  terraform init -input=false -reconfigure 2>/dev/null || true
  terraform workspace select "$ENVIRONMENT" 2>/dev/null || {
    warn "Workspace $ENVIRONMENT not found in $module — skipping (nothing to destroy)."
    cd "$REPO_ROOT"
    return 0
  }

  if ! terraform destroy -input=false -auto-approve $refresh_opt \
    -var="environment=$ENVIRONMENT" \
    ${extra_vars:+ $extra_vars} 2>&1; then
    warn "Destroy failed or partial in $module — check output above. Continuing."
  fi
  cd "$REPO_ROOT"
  log "Done: $module"
}

echo ""
echo "  ═══════════════════════════════════════════════════════════"
echo "  PayFlow Teardown  |  cloud: $CLOUD  |  env: $ENVIRONMENT"
echo "  ═══════════════════════════════════════════════════════════"
echo ""
read -p "  Destroy ALL resources in $CLOUD / $ENVIRONMENT? Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  log "Aborted (did not type 'yes')."
  exit 0
fi
echo ""

if [ "$CLOUD" = "aks" ]; then
  log "Azure (AKS) teardown — destroy in reverse order of spinup..."
  destroy_module "terraform/azure/finops" "FinOps"
  destroy_module "terraform/azure/bastion" "Bastion"
  destroy_module "terraform/azure/managed-services" "PostgreSQL, Redis, Service Bus"
  destroy_module "terraform/azure/spoke-vnet-aks" "AKS + ACR"
  destroy_module "terraform/azure/hub-vnet" "Hub VNet"
  log "AKS teardown complete."
  exit 0
fi

# --- AWS (EKS) teardown: reverse order of spinup ---
log "AWS (EKS) teardown — destroying in reverse order of spinup..."
echo ""

# 1) FinOps (skip refresh: AWS Budgets API often times out on state read)
destroy_module "terraform/aws/finops" "FinOps - budgets and alarms" "-var=aws_account_id=$ACCOUNT" "no_refresh"

# 2) Bastion
destroy_module "terraform/aws/bastion" "Bastion host" "-var=tfstate_bucket=$TFSTATE_BUCKET"

# 3) Managed services - RDS, ElastiCache, MQ (can take 10-20 min)
destroy_module "terraform/aws/managed-services" "RDS, ElastiCache, Amazon MQ" "-var=tfstate_bucket=$TFSTATE_BUCKET"

# 4) EKS spoke - cluster, node groups, ECR
#    Pre-delete EKS S3 buckets via CLI and remove from state (Terraform force_destroy can still fail on versioned buckets).
EKS_DIR="$REPO_ROOT/terraform/aws/spoke-vpc-eks"
EKS_BUCKETS="payflow-eks-cluster-cloudtrail-${ACCOUNT} payflow-eks-cluster-config-${ACCOUNT}"
for b in $EKS_BUCKETS; do
  aws s3 rb "s3://${b}" --force --region "$REGION" 2>/dev/null || true
done
if [ -d "$EKS_DIR" ]; then
  cd "$EKS_DIR"
  terraform init -input=false -reconfigure 2>/dev/null || true
  if terraform workspace select "$ENVIRONMENT" 2>/dev/null; then
    terraform state rm aws_s3_bucket.cloudtrail 2>/dev/null || true
    terraform state rm aws_s3_bucket.config 2>/dev/null || true
  fi
  cd "$REPO_ROOT"
fi
export TF_CLI_ARGS_destroy="-parallelism=1"
destroy_module "terraform/aws/spoke-vpc-eks" "EKS VPC, cluster, nodes" "-var=hub_tfstate_bucket=$TFSTATE_BUCKET"
unset TF_CLI_ARGS_destroy

# 5) Hub VPC
destroy_module "terraform/aws/hub-vpc" "Hub VPC, TGW"

log "Terraform teardown complete."
echo ""

# Optional: delete backend (S3 state + DynamoDB lock)
if [ "${DESTROY_BACKEND:-0}" = "1" ]; then
  log "DESTROY_BACKEND=1 — emptying S3 state bucket and deleting DynamoDB lock table..."
  aws s3 rm "s3://${TFSTATE_BUCKET}/" --recursive --region "$REGION" 2>/dev/null || true
  aws dynamodb delete-table --table-name payflow-tfstate-lock --region "$REGION" 2>/dev/null || true
  log "Backend resources removed. Next spinup will recreate bucket and table if missing."
else
  log "State bucket and DynamoDB table kept. To remove them too: DESTROY_BACKEND=1 ./teardown.sh"
fi

echo ""
log "All done. Run ./spinup.sh to create resources again from scratch."
