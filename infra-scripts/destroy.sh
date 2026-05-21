#!/usr/bin/env bash
# =============================================================================
# PayFlow Infrastructure — DESTROY Script
# =============================================================================
# Destroys all AWS resources in the correct dependency order.
# Safe: shows a plan and asks for confirmation before each module.
# Workspace-aware: auto-detects whether each module's state is in the
# default workspace or a named workspace (handles both spinup strategies).
# Does NOT destroy the S3 state bucket or DynamoDB lock table.
#
# Usage:
#   ./destroy.sh
# =============================================================================
set -euo pipefail
export AWS_PAGER=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[destroy]${NC} $1"; }
success() { echo -e "${GREEN}[ok]${NC}      $1"; }
warn()    { echo -e "${YELLOW}[warn]${NC}    $1"; }
error()   { echo -e "${RED}[error]${NC}   $1"; exit 1; }

banner() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# ── Config ────────────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_ROOT="$REPO_ROOT/terraform/aws"

# ── Pre-flight ────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${RED}${BOLD}"
cat << 'SKULL'
  ██████╗ ███████╗███████╗████████╗██████╗  ██████╗ ██╗   ██╗
  ██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗ ██╔╝
  ██║  ██║█████╗  ███████╗   ██║   ██████╔╝██║   ██║ ╚████╔╝
  ██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██╗██║   ██║  ╚██╔╝
  ██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╔╝   ██║
  ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝    ╚═╝
SKULL
echo -e "${NC}"
echo -e "${BOLD}  PayFlow Infrastructure Destroy${NC}"
echo -e "  Destroys: EKS, RDS, Redis, MQ, bastion, Transit Gateway, VPCs, NAT gateways"
echo -e "  ${GREEN}Keeps:${NC}    S3 state bucket + DynamoDB lock table (so you can re-spinup)"
echo ""

command -v aws       > /dev/null 2>&1 || error "aws CLI not found."
command -v terraform > /dev/null 2>&1 || error "terraform not found."
command -v python3   > /dev/null 2>&1 || error "python3 not found."

ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
  || error "AWS CLI not configured. Run: aws configure"
TFSTATE_BUCKET="payflow-tfstate-${ACCOUNT}"
success "AWS account: $ACCOUNT  region: $REGION"
success "State bucket: $TFSTATE_BUCKET"

# Verify state bucket exists — if not, nothing was ever deployed
aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null \
  || error "State bucket $TFSTATE_BUCKET not found — nothing to destroy."

echo ""
echo -e "${YELLOW}${BOLD}  Destroy order:${NC}"
echo "  1. managed-services  (RDS, ElastiCache Redis, Amazon MQ)"
echo "  2. spoke-vpc-eks     (EKS cluster, nodes, NAT gateway, ECR, security services)"
echo "  3. bastion           (EC2 bastion host, IAM role)"
echo "  4. hub-vpc           (Transit Gateway, hub VPC, subnets)"
echo "  5. github-actions    (IAM OIDC role for CI — optional, low cost)"
echo ""
echo -e "  ${GREEN}Not destroyed:${NC} S3 state bucket, DynamoDB lock table"
echo ""
read -p "  Ready? (yes/no): " go
[[ "$go" =~ ^[Yy](es)?$ ]] || { echo "Aborted."; exit 0; }

START_TIME=$(date +%s)

# =============================================================================
# CORE FUNCTION — destroy_module
# =============================================================================
# Handles the workspace mismatch that exists in this project:
#   - Some modules were applied in the DEFAULT workspace (hub-vpc, bastion)
#   - Some modules were applied in a NAMED workspace (managed-services, spoke-vpc-eks)
#
# Strategy: for each module, try every workspace that might contain state.
# For each candidate workspace, init + plan-destroy. If the plan shows
# resources to destroy, ask for confirmation and apply.
# =============================================================================
destroy_module() {
  local module="$1"          # e.g. "managed-services"
  local description="$2"     # human-readable description
  local s3_key_base="$3"     # S3 key prefix, e.g. "aws/managed-services"
  local extra_var_file="${4:-}"  # optional: path to a tfvars file

  local dir="$TF_ROOT/$module"
  local found_and_destroyed=false

  banner "MODULE: $module — $description"

  if [ ! -d "$dir" ]; then
    warn "Directory $dir not found — skipping."
    return 0
  fi

  # ── Discover which workspaces have state for this module ──────────────────
  # Check default workspace: state is at s3://<bucket>/<key>
  # Check named workspaces: state is at s3://<bucket>/env:/<name>/<key>
  local workspaces_with_state=()

  # Default workspace
  if aws s3api head-object \
      --bucket "$TFSTATE_BUCKET" \
      --key "${s3_key_base}/terraform.tfstate" \
      --region "$REGION" > /dev/null 2>&1; then
    # Check the state has actual resources (not just an empty/null state)
    local resource_count
    resource_count=$(aws s3 cp \
      "s3://${TFSTATE_BUCKET}/${s3_key_base}/terraform.tfstate" - \
      --region "$REGION" 2>/dev/null \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len([r for r in d.get('resources', []) if r.get('mode') == 'managed']))
except:
    print(0)
" 2>/dev/null || echo 0)
    if [ "$resource_count" -gt 0 ]; then
      workspaces_with_state+=("default")
      log "Found state in DEFAULT workspace: $resource_count managed resource(s)"
    else
      log "Default workspace state exists but has 0 managed resources — skipping"
    fi
  fi

  # Named workspaces — check dev and prod (the two this project uses)
  for ws in dev prod; do
    local ws_key="env:/${ws}/${s3_key_base}/terraform.tfstate"
    if aws s3api head-object \
        --bucket "$TFSTATE_BUCKET" \
        --key "$ws_key" \
        --region "$REGION" > /dev/null 2>&1; then
      local ws_resource_count
      ws_resource_count=$(aws s3 cp \
        "s3://${TFSTATE_BUCKET}/${ws_key}" - \
        --region "$REGION" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len([r for r in d.get('resources', []) if r.get('mode') == 'managed']))
except:
    print(0)
" 2>/dev/null || echo 0)
      if [ "$ws_resource_count" -gt 0 ]; then
        workspaces_with_state+=("$ws")
        log "Found state in '$ws' workspace: $ws_resource_count managed resource(s)"
      else
        log "Workspace '$ws' state exists but has 0 managed resources — skipping"
      fi
    fi
  done

  if [ ${#workspaces_with_state[@]} -eq 0 ]; then
    warn "No state found for $module in any workspace. Nothing to destroy."
    return 0
  fi

  # ── Destroy each workspace that has resources ─────────────────────────────
  cd "$dir"

  for ws in "${workspaces_with_state[@]}"; do
    echo ""
    log "Initialising for workspace: $ws"
    unset TF_WORKSPACE

    terraform init -reconfigure -input=false \
      -backend-config="bucket=$TFSTATE_BUCKET" \
      -backend-config="region=$REGION" \
      -backend-config="dynamodb_table=payflow-tfstate-lock" \
      > /tmp/tf-init.log 2>&1 || {
      warn "terraform init failed for $module ($ws workspace):"
      cat /tmp/tf-init.log
      continue
    }

    if [ "$ws" = "default" ]; then
      terraform workspace select default > /dev/null 2>&1 || true
    else
      terraform workspace select "$ws" 2>/dev/null \
        || terraform workspace new "$ws" 2>/dev/null \
        || terraform workspace select "$ws"
    fi

    log "Planning destroy ($ws workspace)..."
    local var_file_arg=""
    if [ -n "$extra_var_file" ] && [ -f "$extra_var_file" ]; then
      var_file_arg="-var-file=$extra_var_file"
    fi

    if ! terraform plan -destroy -input=false $var_file_arg \
        -out=/tmp/destroy_${module}_${ws}.plan \
        > /tmp/tf-plan.log 2>&1; then

      # If plan failed because a remote_state data source has no outputs (e.g. hub-vpc
      # state was already destroyed before spoke-vpc-eks runs), retry with -refresh=false
      # so Terraform uses cached state for data sources instead of re-reading from S3.
      if grep -q "object with no attributes\|Unsupported attribute" /tmp/tf-plan.log 2>/dev/null; then
        warn "Remote state data source empty — retrying with -refresh=false..."
        if ! terraform plan -destroy -input=false -refresh=false $var_file_arg \
            -out=/tmp/destroy_${module}_${ws}.plan \
            > /tmp/tf-plan.log 2>&1; then
          warn "Plan failed even with -refresh=false for $module ($ws workspace):"
          cat /tmp/tf-plan.log
          continue
        fi
        log "Plan succeeded with -refresh=false"
      else
        warn "Plan failed for $module ($ws workspace):"
        cat /tmp/tf-plan.log
        # Check for stale lock
        if grep -q "Error acquiring the state lock" /tmp/tf-plan.log 2>/dev/null; then
          LOCK_ID=$(grep -oP '(?<=ID:        )[\w-]+' /tmp/tf-plan.log || echo "")
          warn "Stale state lock detected. To unlock:"
          warn "  cd $dir && terraform workspace select $ws && terraform force-unlock $LOCK_ID"
        fi
        continue
      fi
    fi

    local to_destroy
    to_destroy=$(terraform show -json /tmp/destroy_${module}_${ws}.plan 2>/dev/null \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    dels = [r['address'] for r in d.get('resource_changes', [])
            if 'delete' in r.get('change', {}).get('actions', [])]
    print(len(dels))
    for r in dels[:20]:
        print('  -', r)
except Exception as e:
    print('0')
" 2>/dev/null || echo "0")

    local count
    count=$(echo "$to_destroy" | head -1)

    if [ "$count" -eq 0 ] 2>/dev/null; then
      log "Plan shows 0 resources to destroy in $ws workspace — skipping."
      continue
    fi

    echo ""
    echo -e "${YELLOW}  Workspace '$ws' — resources to destroy: ${BOLD}$count${NC}"
    echo "$to_destroy" | tail -n +2
    echo ""
    read -p "  Destroy $module ($ws workspace)? (yes/no): " confirm
    [[ "$confirm" =~ ^[Yy](es)?$ ]] || { warn "Skipped $module ($ws workspace)."; continue; }

    echo ""
    log "Destroying $module ($ws workspace)..."
    if terraform apply -destroy -input=false /tmp/destroy_${module}_${ws}.plan; then
      success "$module ($ws workspace) destroyed."
      found_and_destroyed=true
    else
      warn "$module ($ws workspace) destroy failed. Check errors above."
    fi
  done

  cd "$REPO_ROOT"
  $found_and_destroyed || warn "Nothing was destroyed for $module."
  echo ""
}

# =============================================================================
# PRE-DESTROY CLEANUP — non-Terraform-managed resources that block VPC deletion
# =============================================================================
# GuardDuty auto-creates interface VPC endpoints in every VPC it monitors.
# These endpoints are NOT in Terraform state, so terraform destroy does not
# remove them. They hold ENIs in the hub VPC subnets, preventing subnet and
# VPC deletion. Delete GuardDuty detectors first so the endpoints are removed
# before hub-vpc runs.
cleanup_guardduty() {
  log "Checking for GuardDuty detectors (auto-creates VPC endpoints that block hub-vpc destroy)..."
  local detectors
  detectors=$(aws guardduty list-detectors --region "$REGION" \
    --query 'DetectorIds[]' --output text 2>/dev/null || true)

  if [ -z "$detectors" ]; then
    log "No GuardDuty detectors found."
    return 0
  fi

  for det in $detectors; do
    log "Deleting GuardDuty detector: $det"
    aws guardduty delete-detector --detector-id "$det" --region "$REGION" 2>/dev/null || true
  done

  # Also explicitly delete any leftover interface endpoints in the hub VPC
  local hub_vpc
  hub_vpc=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=*hub*" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || true)

  if [ -n "$hub_vpc" ] && [ "$hub_vpc" != "None" ]; then
    local endpoints
    endpoints=$(aws ec2 describe-vpc-endpoints \
      --filters "Name=vpc-id,Values=$hub_vpc" "Name=vpc-endpoint-type,Values=Interface" \
      --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
      --output text --region "$REGION" 2>/dev/null || true)

    if [ -n "$endpoints" ]; then
      log "Deleting interface VPC endpoints in hub VPC: $endpoints"
      aws ec2 delete-vpc-endpoints \
        --vpc-endpoint-ids $endpoints \
        --region "$REGION" 2>/dev/null || true
      log "Waiting 30s for endpoint ENIs to release..."
      sleep 30
    else
      log "No interface VPC endpoints in hub VPC."
    fi
  fi
  success "GuardDuty cleanup complete."
}

cleanup_guardduty

# Kubernetes creates ELB security groups (k8s-elb-*) and classic ELBs for
# Services of type LoadBalancer. When the EKS cluster is deleted by Terraform,
# these are NOT cleaned up because Kubernetes never runs a graceful shutdown.
# They hold ENIs in the spoke VPC subnets, preventing subnet/VPC deletion.
cleanup_k8s_elbs() {
  log "Checking for Kubernetes-created ELBs and security groups..."

  local spoke_vpc
  spoke_vpc=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=*spoke*,*eks*" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || true)

  if [ -z "$spoke_vpc" ] || [ "$spoke_vpc" = "None" ]; then
    log "No spoke VPC found — nothing to clean up."
    return 0
  fi

  # Delete classic ELBs whose ENIs are in spoke subnets
  local classic_elbs
  classic_elbs=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$spoke_vpc'].LoadBalancerName" \
    --output text 2>/dev/null || true)
  for elb in $classic_elbs; do
    log "Deleting classic ELB: $elb"
    aws elb delete-load-balancer --load-balancer-name "$elb" --region "$REGION" 2>/dev/null || true
  done

  # Delete ELBv2 (NLB/ALB) in spoke VPC
  local v2_arns
  v2_arns=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$spoke_vpc'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  for arn in $v2_arns; do
    log "Deleting ELBv2: $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
  done

  # ELB deletion is async — ENIs are released in the background after the API call
  # returns. Sleep BEFORE trying to delete SGs, otherwise the SG delete fails
  # silently (|| true) because ENIs still hold the SG, and the VPC hangs later.
  if [ -n "$classic_elbs$v2_arns" ]; then
    log "Waiting 60s for ELB ENIs to release before deleting security groups..."
    sleep 60
  fi

  # Delete all K8s-managed security groups in the spoke VPC:
  #   k8s-elb-*            — classic in-tree controller
  #   k8s-traffic-*        — AWS Load Balancer Controller (shared backend SG)
  #   tagged elbv2.k8s.aws/cluster — AWS Load Balancer Controller (frontend SG)
  #   k8s-*                — catch-all for any other ALB controller SGs
  local k8s_sgs
  k8s_sgs=$(
    {
      aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$spoke_vpc" "Name=group-name,Values=k8s-elb-*" \
        --query 'SecurityGroups[].GroupId' --output text --region "$REGION" 2>/dev/null || true
      aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$spoke_vpc" "Name=group-name,Values=k8s-traffic-*" \
        --query 'SecurityGroups[].GroupId' --output text --region "$REGION" 2>/dev/null || true
      aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$spoke_vpc" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
        --query 'SecurityGroups[].GroupId' --output text --region "$REGION" 2>/dev/null || true
      aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$spoke_vpc" "Name=group-name,Values=k8s-*" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || true
    } | tr '\t' '\n' | grep -v '^$' | sort -u | xargs
  )

  delete_sg() {
    local sg="$1"
    [ -z "$sg" ] && return 0
    # Use security-group-rule IDs (not ip-permissions JSON) — avoids format issues
    local ingress_rules egress_rules
    ingress_rules=$(aws ec2 describe-security-group-rules --region "$REGION" \
      --filters "Name=group-id,Values=$sg" \
      --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' \
      --output text 2>/dev/null || true)
    egress_rules=$(aws ec2 describe-security-group-rules --region "$REGION" \
      --filters "Name=group-id,Values=$sg" \
      --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' \
      --output text 2>/dev/null || true)
    [ -n "$ingress_rules" ] && \
      aws ec2 revoke-security-group-ingress --group-id "$sg" \
        --security-group-rule-ids $ingress_rules --region "$REGION" 2>/dev/null || true
    [ -n "$egress_rules" ] && \
      aws ec2 revoke-security-group-egress --group-id "$sg" \
        --security-group-rule-ids $egress_rules --region "$REGION" 2>/dev/null || true
    log "Deleting k8s security group: $sg"
    if ! aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null; then
      warn "Could not delete $sg yet — will retry after Terraform destroy"
    fi
  }

  for sg in $k8s_sgs; do
    delete_sg "$sg"
  done

  # ALB controller target groups are NOT deleted when the ALB is removed and
  # are NOT in Terraform state — they linger pointing at the (soon-to-be-deleted)
  # VPC and accumulate across spinup/teardown cycles. Delete every target group
  # the payflow ALB controller created (named k8s-payflow-*). They can only be
  # deleted once their load balancer is gone, which the steps above ensure.
  local k8s_tgs
  k8s_tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-payflow-')].TargetGroupArn" \
    --output text 2>/dev/null || true)
  for tg in $k8s_tgs; do
    log "Deleting orphaned target group: $(basename "$(dirname "$tg")")"
    aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" 2>/dev/null \
      || warn "Could not delete target group $tg yet"
  done

  if [ -z "$classic_elbs$v2_arns$k8s_sgs$k8s_tgs" ]; then
    log "No Kubernetes ELBs, SGs, or target groups found."
  fi
  success "Kubernetes ELB cleanup complete."
}

cleanup_k8s_elbs

# EBS volumes created by Kubernetes dynamic provisioning (gp2 StorageClass) are
# NOT in Terraform state — the storage provisioner creates them outside Terraform.
# When EKS is deleted by Terraform without a graceful K8s shutdown, these volumes
# are orphaned (state = available). They block nothing but cost money indefinitely.
cleanup_eks_ebs_volumes() {
  local cluster_name="payflow-eks-cluster"
  log "Checking for EBS volumes tagged with cluster: $cluster_name ..."

  local volumes
  volumes=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${cluster_name}" \
    --query 'Volumes[*].VolumeId' --output text 2>/dev/null || true)

  if [ -z "$volumes" ]; then
    log "No EKS-tagged EBS volumes found."
    return 0
  fi

  log "Found EKS-tagged volumes: $volumes"

  # Force-detach any that are still in-use
  for vol in $volumes; do
    local state
    state=$(aws ec2 describe-volumes --volume-ids "$vol" --region "$REGION" \
      --query 'Volumes[0].State' --output text 2>/dev/null || echo "deleted")
    if [ "$state" = "in-use" ]; then
      log "Force-detaching in-use volume: $vol"
      aws ec2 detach-volume --volume-id "$vol" --force --region "$REGION" 2>/dev/null || true
    fi
  done

  # Wait for detachments to settle
  log "Waiting 20s for detachments to complete..."
  sleep 20

  # Delete all
  for vol in $volumes; do
    local state
    state=$(aws ec2 describe-volumes --volume-ids "$vol" --region "$REGION" \
      --query 'Volumes[0].State' --output text 2>/dev/null || echo "deleted")
    if [ "$state" = "available" ]; then
      log "Deleting EBS volume: $vol"
      aws ec2 delete-volume --volume-id "$vol" --region "$REGION" 2>/dev/null || true
    else
      warn "Volume $vol is in state '$state' — skipping"
    fi
  done

  success "EBS volume cleanup complete."
}

cleanup_eks_ebs_volumes

# =============================================================================
# DESTROY SEQUENCE — reverse of spinup order
# =============================================================================

# S3 key bases must match the backend.tf key fields in each module
destroy_module \
  "managed-services" \
  "RDS PostgreSQL, ElastiCache Redis, Amazon MQ RabbitMQ — ~15 min" \
  "aws/managed-services" \
  "$TF_ROOT/managed-services/terraform.tfvars"

destroy_module \
  "spoke-vpc-eks" \
  "EKS cluster, nodes, NAT gateway, ECR repos, WAF, GuardDuty — ~15 min" \
  "aws/eks" \
  "$TF_ROOT/spoke-vpc-eks/terraform.tfvars"

# Second-pass SG cleanup: any k8s SGs that survived the pre-destroy phase
# (e.g. ENIs held during the initial cleanup window) are deleted now that
# Terraform has torn down the EKS cluster and all ENIs have been released.
cleanup_k8s_elbs

destroy_module \
  "bastion" \
  "Bastion EC2, Elastic IP, IAM role — ~2 min" \
  "aws/bastion" \
  "$TF_ROOT/bastion/terraform.tfvars"

destroy_module \
  "hub-vpc" \
  "Transit Gateway, hub VPC, NAT gateway, Internet Gateway — ~3 min" \
  "aws/hub-vpc" \
  "$TF_ROOT/hub-vpc/terraform.tfvars"

# github-actions is just an IAM role — not a running cost, but clean it up
destroy_module \
  "github-actions" \
  "GitHub Actions OIDC IAM role — ~1 min" \
  "aws/github-actions" \
  ""

# Also clean up finops if it exists
destroy_module \
  "finops" \
  "FinOps budgets, anomaly detection — ~1 min" \
  "aws/finops" \
  ""

# =============================================================================
# POST-DESTROY VERIFICATION
# =============================================================================
banner "VERIFICATION — Checking for remaining billable resources"

EKS=$(aws eks list-clusters --region "$REGION" --query 'clusters' --output text 2>/dev/null)
NAT=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
TGW=$(aws ec2 describe-transit-gateways --region "$REGION" \
  --filters Name=state,Values=available \
  --query 'TransitGateways[].TransitGatewayId' --output text 2>/dev/null)
EC2=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
RDS=$(aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[?DBInstanceStatus!=`deleting`].DBInstanceIdentifier' \
  --output text 2>/dev/null)
MQ=$(aws mq list-brokers --region "$REGION" \
  --query 'BrokerSummaries[?BrokerState!=`DELETION_IN_PROGRESS`].BrokerName' \
  --output text 2>/dev/null)
REDIS=$(aws elasticache describe-cache-clusters --region "$REGION" \
  --query 'CacheClusters[?CacheClusterStatus!=`deleting`].CacheClusterId' \
  --output text 2>/dev/null)

ISSUES=0
[ -z "$EKS"   ] && success "EKS clusters:    none" || { warn "EKS still running:   $EKS";   ISSUES=$((ISSUES+1)); }
[ -z "$NAT"   ] && success "NAT gateways:    none" || { warn "NAT still running:   $NAT";   ISSUES=$((ISSUES+1)); }
[ -z "$TGW"   ] && success "Transit GWs:     none" || { warn "TGW still active:    $TGW";   ISSUES=$((ISSUES+1)); }
[ -z "$EC2"   ] && success "EC2 instances:   none" || { warn "EC2 still running:   $EC2";   ISSUES=$((ISSUES+1)); }
[ -z "$RDS"   ] && success "RDS instances:   none" || { warn "RDS still running:   $RDS";   ISSUES=$((ISSUES+1)); }
[ -z "$MQ"    ] && success "Amazon MQ:       none" || { warn "MQ still running:    $MQ";    ISSUES=$((ISSUES+1)); }
[ -z "$REDIS" ] && success "ElastiCache:     none" || { warn "Redis still running: $REDIS"; ISSUES=$((ISSUES+1)); }

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
if [ "$ISSUES" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✓ ALL CLEAR — infrastructure fully destroyed${NC}"
  echo -e "${GREEN}${BOLD}  Remaining cost: ~\$0.02/month (S3 state bucket only)${NC}"
  echo -e "${GREEN}${BOLD}  Time taken: ${ELAPSED} minutes${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
  echo -e "${YELLOW}${BOLD}  ⚠ $ISSUES resource type(s) may still be running — check warnings above${NC}"
  echo -e "${YELLOW}  Re-run ./destroy.sh or investigate manually in the AWS console${NC}"
fi
echo ""
