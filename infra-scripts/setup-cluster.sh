#!/usr/bin/env bash
# =============================================================================
# PayFlow Cluster Setup Script
# =============================================================================
# Runs AFTER spinup.sh has completed all Terraform infrastructure.
#
# EKS API endpoint is PRIVATE (endpoint_public_access = false).
# This script runs on your LOCAL machine. It:
#   1. Collects values from AWS (account, bastion ID, IRSA ARNs)
#   2. Reads the ArgoCD Application manifests from the local repo
#   3. Generates a self-contained bastion-side script with all values embedded
#   4. Uploads it to the Terraform state S3 bucket (presigned URL — no S3 IAM
#      permissions needed on the bastion)
#   5. Executes it on the bastion via SSM Run Command (kubectl/helm run there)
#   6. Polls for completion and streams the output
#
# Usage:
#   ./setup-cluster.sh
#   ./setup-cluster.sh --skip-argocd   (if ArgoCD already installed)
#   ./setup-cluster.sh --skip-eso      (if ESO already installed)
# =============================================================================
set -euo pipefail
export AWS_PAGER=""

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[setup]${NC} $1"; }
success() { echo -e "${GREEN}[ok]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $1"; }
error()   { echo -e "${RED}[error]${NC} $1"; exit 1; }
banner()  {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# ── Flags ────────────────────────────────────────────────────────────────────
SKIP_ARGOCD=false
SKIP_ESO=false
for arg in "$@"; do
  case $arg in
    --skip-argocd) SKIP_ARGOCD=true ;;
    --skip-eso)    SKIP_ESO=true ;;
  esac
done

# ── Config ────────────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${EKS_CLUSTER_NAME:-payflow-eks-cluster}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Temp files — cleaned up on exit
BASTION_SCRIPT=$(mktemp /tmp/bastion_setup_XXXXXX.sh)
PARAMS_FILE=$(mktemp /tmp/ssm_params_XXXXXX.json)
trap 'rm -f "$BASTION_SCRIPT" "$PARAMS_FILE"' EXIT

# =============================================================================
# PART 1 — LOCAL PRE-FLIGHT
# =============================================================================
banner "PRE-FLIGHT CHECKS (local)"

command -v aws  > /dev/null 2>&1 || error "aws CLI not found. Install: brew install awscli"
command -v jq   > /dev/null 2>&1 || error "jq not found. Install: brew install jq"
command -v helm > /dev/null 2>&1 || error "helm not found. Install: brew install helm"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
  || error "AWS CLI not configured. Run: aws configure"
success "AWS account: $ACCOUNT  region: $REGION"

CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.status' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
[ "$CLUSTER_STATUS" = "ACTIVE" ] \
  || error "EKS cluster '$CLUSTER_NAME' not ACTIVE (status: $CLUSTER_STATUS). Run spinup.sh first."
success "EKS cluster $CLUSTER_NAME → $CLUSTER_STATUS"

# =============================================================================
# PART 2 — COLLECT VALUES
# =============================================================================
banner "COLLECTING VALUES"

TFSTATE_BUCKET="payflow-tfstate-${ACCOUNT}"
aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null \
  || error "Terraform state bucket '$TFSTATE_BUCKET' not found. Run spinup.sh first."
success "Terraform state bucket: $TFSTATE_BUCKET"

log "Looking up bastion instance..."
BASTION_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=payflow-bastion" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region "$REGION" 2>/dev/null || echo "None")
[ "$BASTION_ID" != "None" ] && [ -n "$BASTION_ID" ] \
  || error "Bastion not running. Run spinup.sh first."
success "Bastion: $BASTION_ID"

log "Verifying SSM connectivity..."
SSM_STATUS=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$BASTION_ID" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text --region "$REGION" 2>/dev/null || echo "Unknown")
[ "$SSM_STATUS" = "Online" ] \
  || error "Bastion SSM status: $SSM_STATUS. Check instance profile and SSM agent."
success "Bastion SSM: Online"

ESO_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/payflow-eks-cluster-external-secrets-irsa"
IMAGE_UPDATER_ROLE="arn:aws:iam::${ACCOUNT}:role/payflow-eks-cluster-image-updater-irsa"

aws iam get-role --role-name payflow-eks-cluster-external-secrets-irsa \
  --region "$REGION" > /dev/null 2>&1 \
  || error "ESO IRSA role not found. Run spinup.sh first."
success "ESO IRSA: $ESO_ROLE_ARN"

# ── Auto-update WAF ARN in values-dev.yaml ────────────────────────────────────
# WAF web ACL is recreated on every spinup with a new ARN. If values-dev.yaml
# still has the previous spinup's ARN the ALB controller fails to associate it
# and ArgoCD blocks waiting for a healthy Ingress, preventing app pods from starting.
log "Reading WAF ARN from Terraform output..."
WAF_ARN=$(terraform -chdir="$REPO_ROOT/terraform/aws/spoke-vpc-eks" output -raw waf_web_acl_arn 2>/dev/null || echo "")
[ -n "$WAF_ARN" ] || error "Could not read waf_web_acl_arn from Terraform. Run spinup.sh first."
success "WAF ARN: $WAF_ARN"

CURRENT_WAF=$(grep 'wafArn:' "$REPO_ROOT/helm/payflow/values-dev.yaml" | sed 's/.*wafArn: *"\(.*\)"/\1/')
if [ "$CURRENT_WAF" != "$WAF_ARN" ]; then
  log "Updating WAF ARN in values-dev.yaml ($CURRENT_WAF → $WAF_ARN)..."
  sed -i.bak "s|wafArn:.*|wafArn: \"$WAF_ARN\"|" "$REPO_ROOT/helm/payflow/values-dev.yaml" \
    && rm -f "$REPO_ROOT/helm/payflow/values-dev.yaml.bak"
  git -C "$REPO_ROOT" add helm/payflow/values-dev.yaml
  git -C "$REPO_ROOT" commit -m "fix: update WAF ARN for new spinup"
  git -C "$REPO_ROOT" push
  success "WAF ARN updated and pushed"
else
  success "WAF ARN already current — no update needed"
fi

# Read ArgoCD Application manifests from local repo
APP_MANIFEST=$(cat "$REPO_ROOT/helm/argocd/application.yaml") \
  || error "helm/argocd/application.yaml not found in $REPO_ROOT"
MON_MANIFEST=$(cat "$REPO_ROOT/helm/argocd/monitoring-application.yaml") \
  || error "helm/argocd/monitoring-application.yaml not found in $REPO_ROOT"
success "ArgoCD manifests loaded"

# ── ROOT-CAUSE FIX: detect ECR tag + bake it into the Application manifest ─────
# ArgoCD's automated sync fires the instant the Application is applied. If
# global.imageTag isn't ALREADY set at that moment, it renders with the
# values.yaml default and the db-migration PreSync hook is created pulling a
# nonexistent tag -> ImagePullBackOff -> stuck argocd hook-finalizer -> ArgoCD
# caches the bad render and keeps recreating it. That cascade is what forced the
# manual finalizer-removal + hard-refresh recovery on past spinups.
#
# Fix: (1) hard-fail if ECR has no images yet (enforces spinup -> CI -> setup
# order instead of just warning), and (2) inject global.imageTag into the
# manifest's helm.parameters NOW so the very first reconcile uses the right tag.
log "Detecting latest image tag from ECR (api-gateway)..."
LATEST_TAG=$(aws ecr describe-images \
  --repository-name "${CLUSTER_NAME}/api-gateway" \
  --region "$REGION" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text 2>/dev/null || echo "")
if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "None" ]; then
  error "ECR has no api-gateway image yet. Correct order: spinup.sh -> push to main (let CI build+push images) -> setup-cluster.sh. Wait for CI to finish, then re-run."
fi
# The db-migration PreSync hook pulls db-migrations:<tag> first — verify it exists.
aws ecr describe-images \
  --repository-name "${CLUSTER_NAME}/db-migrations" \
  --image-ids imageTag="$LATEST_TAG" \
  --region "$REGION" >/dev/null 2>&1 \
  || error "db-migrations:$LATEST_TAG missing in ECR (CI may still be building). Wait for CI to finish, then re-run."
success "ECR image tag: $LATEST_TAG"

APP_MANIFEST=$(printf '%s\n' "$APP_MANIFEST" | python3 -c '
import sys
m = sys.stdin.read()
tag = sys.argv[1]
inject = "      parameters:\n        - name: global.imageTag\n          value: \"%s\"\n" % tag
m = m.replace("        - values-dev.yaml\n", "        - values-dev.yaml\n" + inject, 1)
sys.stdout.write(m)
' "$LATEST_TAG") || error "Failed to inject imageTag into Application manifest"
printf '%s\n' "$APP_MANIFEST" | grep -q "global.imageTag" \
  || error "imageTag injection failed — 'global.imageTag' not found in manifest"
success "global.imageTag=$LATEST_TAG baked into Application manifest"

# Pre-encode ECR creds script as base64 so the unquoted BASTION_EOF heredoc
# below can embed a literal b64 string instead of expanding $(aws ecr ...) locally.
# The bastion decodes this at runtime, producing a dynamic script that calls
# aws ecr get-login-password fresh each time (ECR tokens expire after 12 hours).
ECR_CREDS_B64=$(printf '#!/bin/sh\nprintf "AWS:%%s" "$(aws ecr get-login-password --region %s)"\n' "$REGION" | base64 | tr -d '\n')
success "ECR creds script pre-encoded"

# Pre-render the bootstrap resources (ClusterSecretStore, ExternalSecrets, ConfigMap) that the
# PreSync migration hook needs before it runs.  ArgoCD applies these in sync-waves 0/1/-1, but
# the PreSync hook runs BEFORE any waves — so on a fresh cluster db-secrets doesn't exist yet
# and the migration job fails with CreateContainerConfigError.  Fix: apply them manually via
# setup-cluster.sh Step 3.5, right after ESO is ready.
log "Pre-rendering bootstrap ESO + ConfigMap YAML via helm template..."
BOOTSTRAP_YAML=$(helm template payflow "$REPO_ROOT/helm/payflow" \
  -f "$REPO_ROOT/helm/payflow/values.yaml" \
  -f "$REPO_ROOT/helm/payflow/values-dev.yaml" \
  --namespace payflow \
  --set global.imageTag=placeholder \
  -s templates/clustersecretstore.yaml \
  -s templates/externalsecret.yaml \
  -s templates/configmap.yaml 2>/dev/null) \
  || error "helm template failed. Is the payflow chart valid? Run: helm lint helm/payflow"
BOOTSTRAP_YAML_B64=$(echo "$BOOTSTRAP_YAML" | base64 | tr -d '\n')
success "Bootstrap YAML pre-rendered (ClusterSecretStore + ExternalSecrets + ConfigMap)"

# =============================================================================
# PART 3 — GENERATE BASTION SCRIPT
# =============================================================================
banner "GENERATING BASTION SCRIPT"

# All values below are expanded NOW on the local machine and hard-coded into
# the generated script. The bastion needs no Terraform state access.
cat > "$BASTION_SCRIPT" << BASTION_EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:\$PATH"
export HOME="/root"  # SSM Run Command sets HOME="" — set it so kubectl/helm find their config

# Hard-coded values from local Terraform outputs — do not edit manually
CLUSTER_NAME="${CLUSTER_NAME}"
REGION="${REGION}"
ACCOUNT="${ACCOUNT}"
ESO_ROLE_ARN="${ESO_ROLE_ARN}"
IMAGE_UPDATER_ROLE="${IMAGE_UPDATER_ROLE}"
SKIP_ARGOCD="${SKIP_ARGOCD}"
SKIP_ESO="${SKIP_ESO}"

log()     { echo "[setup] \$1"; }
success() { echo "[ok]    \$1"; }
warn()    { echo "[warn]  \$1"; }
err()     { echo "[error] \$1"; exit 1; }
banner()  { echo ""; echo "=== \$1 ==="; echo ""; }

# ── Step 1 — kubeconfig ──────────────────────────────────────────────────────
banner "STEP 1 — kubeconfig + nodes"
aws eks update-kubeconfig --name "\$CLUSTER_NAME" --region "\$REGION" --no-cli-pager

log "Waiting for Ready nodes (up to 3 minutes)..."
NODE_COUNT=0
for i in \$(seq 1 18); do
  NODE_COUNT=\$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  [ "\$NODE_COUNT" -gt 0 ] && break
  printf "."; sleep 10
done
echo ""
[ "\$NODE_COUNT" -gt 0 ] || err "No Ready nodes after 3 minutes. Check EKS node group."
success "\$NODE_COUNT node(s) Ready"
kubectl get nodes --no-headers

# ── Step 2 — ArgoCD ──────────────────────────────────────────────────────────
if [ "\$SKIP_ARGOCD" = "true" ]; then
  warn "Skipping ArgoCD (--skip-argocd)"
else
  banner "STEP 2 — ArgoCD"
  ALREADY_RUNNING=\$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
    --no-headers 2>/dev/null | grep -c Running || true)
  if [ "\$ALREADY_RUNNING" -gt 0 ]; then
    warn "ArgoCD already running — skipping install"
  else
    kubectl create namespace argocd 2>/dev/null || true
    log "Installing ArgoCD (server-side apply required for large CRDs)..."
    kubectl apply --server-side \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
      -n argocd 2>&1 | tail -3
    log "Waiting for argocd-server (up to 3 minutes)..."
    kubectl wait --for=condition=available deployment/argocd-server \
      -n argocd --timeout=180s
    success "ArgoCD deployed"
  fi

  # Patch to internal NLB if not already done
  ARGOCD_TYPE=\$(kubectl get svc argocd-server -n argocd \
    -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
  ARGOCD_INTERNAL=\$(kubectl get svc argocd-server -n argocd \
    -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-internal}' \
    2>/dev/null || echo "")
  if [ "\$ARGOCD_TYPE" != "LoadBalancer" ] || [ "\$ARGOCD_INTERNAL" != "true" ]; then
    log "Patching ArgoCD service to internal NLB..."
    kubectl patch svc argocd-server -n argocd -p \
      '{"metadata":{"annotations":{"service.beta.kubernetes.io/aws-load-balancer-internal":"true","service.beta.kubernetes.io/aws-load-balancer-scheme":"internal"}},"spec":{"type":"LoadBalancer"}}'
  fi

  log "Waiting for internal NLB hostname (up to 2 minutes)..."
  ARGOCD_URL=""
  for i in \$(seq 1 24); do
    ARGOCD_URL=\$(kubectl get svc argocd-server -n argocd \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [ -n "\$ARGOCD_URL" ] && break
    printf "."; sleep 5
  done
  echo ""
  if [ -n "\$ARGOCD_URL" ]; then
    ARGOCD_PASSWORD=\$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<check manually>")
    success "ArgoCD internal NLB: https://\$ARGOCD_URL"
    echo "  ArgoCD user:     admin"
    echo "  ArgoCD password: \$ARGOCD_PASSWORD"
    echo "  NOTE: NLB is VPC-only. Access via bastion SSM session."
  else
    warn "ArgoCD NLB hostname not yet assigned."
    warn "Check later: kubectl get svc argocd-server -n argocd"
  fi
fi

# ── Step 2.5 — Patch argocd-cm with PVC health customization ─────────────────
# gp2 StorageClass uses WaitForFirstConsumer; postgres-backup PVC stays Pending
# until the backup CronJob first runs.  ArgoCD treats Pending = Degraded and
# blocks subsequent sync waves.  This Lua override maps Pending → Healthy so
# ArgoCD can proceed past the sync wave without waiting for the CronJob to run.
# Key format for core K8s resources: just the Kind name, no group/version prefix.
banner "STEP 2.5 — argocd-cm PVC health check"
cat > /tmp/patch_argocd_cm.py <<'PYEOF'
import subprocess, json, sys

check = subprocess.run(
    ["kubectl", "get", "configmap", "argocd-cm", "-n", "argocd",
     "-o", "jsonpath={.data.resource\\.customizations\\.health\\.PersistentVolumeClaim}"],
    capture_output=True, text=True)
if check.stdout.strip():
    print("[ok]    argocd-cm PVC health customization already present")
    sys.exit(0)

lua = (
    "hs = {}\n"
    "if obj.status ~= nil then\n"
    "  if obj.status.phase == \"Pending\" then\n"
    "    hs.status = \"Healthy\"\n"
    "    hs.message = \"Waiting for first consumer (WaitForFirstConsumer storage class)\"\n"
    "    return hs\n"
    "  end\n"
    "  if obj.status.phase == \"Bound\" then\n"
    "    hs.status = \"Healthy\"\n"
    "    return hs\n"
    "  end\n"
    "end\n"
    "hs.status = \"Progressing\"\n"
    "return hs\n"
)
patch = {"data": {"resource.customizations.health.PersistentVolumeClaim": lua}}
r = subprocess.run(
    ["kubectl", "patch", "configmap", "argocd-cm", "-n", "argocd",
     "--type", "merge", "-p", json.dumps(patch)],
    capture_output=True, text=True)
if r.returncode != 0:
    print("STDERR:", r.stderr, file=sys.stderr)
    sys.exit(r.returncode)
print("[ok]    argocd-cm PVC health customization applied")
PYEOF
if command -v python3 >/dev/null 2>&1; then
  python3 /tmp/patch_argocd_cm.py || warn "PVC health patch failed — Pending PVCs may block sync"
else
  warn "python3 not found — PVC health patch skipped (apply manually if postgres-backup PVC blocks sync)"
fi

# ── Step 3 — External Secrets Operator ──────────────────────────────────────
if [ "\$SKIP_ESO" = "true" ]; then
  warn "Skipping ESO (--skip-eso)"
else
  banner "STEP 3 — External Secrets Operator"
  ESO_RUNNING=\$(kubectl get pods -n external-secrets --no-headers 2>/dev/null \
    | grep -c Running || true)
  if [ "\$ESO_RUNNING" -gt 0 ]; then
    warn "ESO already running — skipping"
  else
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo update 2>&1 | grep -E 'Update|Successfully|error' || true
    log "Installing External Secrets Operator..."
    helm install external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --create-namespace \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="\$ESO_ROLE_ARN" \
      --wait --timeout 3m 2>&1 | tail -5
    success "ESO installed with IRSA: \$ESO_ROLE_ARN"
  fi
fi

# ── Step 3.5 — Bootstrap ESO resources ─────────────────────────────────────
# The db-migration PreSync hook needs db-secrets and app-config to exist BEFORE
# it runs.  ArgoCD applies these in sync-waves 0/1/-1 (main sync), but PreSync
# runs before all waves.  On a fresh cluster this causes a deadlock:
#   PreSync needs db-secrets → db-secrets requires ExternalSecret → ExternalSecret
#   is created by the main sync → main sync only runs after PreSync succeeds.
# Fix: apply ClusterSecretStore + ExternalSecrets + ConfigMap manually here so
# ESO can create db-secrets before ArgoCD's first sync attempt.
banner "STEP 3.5 — Bootstrap ESO resources (pre-migration secrets)"
kubectl create namespace payflow 2>/dev/null || true
log "Applying ClusterSecretStore, ExternalSecrets, and ConfigMap..."
echo "${BOOTSTRAP_YAML_B64}" | base64 -d | kubectl apply -f - 2>&1
log "Waiting for ESO to create db-secrets (up to 2 minutes)..."
SECRET_READY=0
for i in \$(seq 1 24); do
  if kubectl get secret db-secrets -n payflow &>/dev/null; then
    SECRET_READY=1
    break
  fi
  printf "."; sleep 5
done
echo ""
if [ "\$SECRET_READY" -eq 1 ]; then
  success "db-secrets synced by ESO"
else
  warn "db-secrets not yet present after 2 minutes."
  warn "Check ESO logs: kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets"
  warn "The migration PreSync hook may fail — retry the sync after secrets appear."
fi

# ── Step 4 — AWS Load Balancer Controller ────────────────────────────────────
# Required for Ingress objects to create ALBs.  Without this, the frontend
# Ingress exists in Kubernetes but no real ALB is ever created — the app
# is unreachable from the internet.
banner "STEP 4 — AWS Load Balancer Controller"
ALB_ROLE_ARN="arn:aws:iam::\${ACCOUNT}:role/\${CLUSTER_NAME}-alb-controller-irsa"
VPC_ID=\$(aws eks describe-cluster --name "\$CLUSTER_NAME" --region "\$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || echo "")

if kubectl get deployment aws-load-balancer-controller -n kube-system &>/dev/null; then
  warn "AWS Load Balancer Controller already installed"
else
  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update 2>&1 | grep -E 'Update|Successfully|error' || true
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="\$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=\$ALB_ROLE_ARN" \
    --set region="\$REGION" \
    --set vpcId="\$VPC_ID" \
    --wait --timeout 5m 2>&1 | tail -5
  success "AWS Load Balancer Controller installed"
fi

# ── Step 4b — metrics-server ─────────────────────────────────────────────────
banner "STEP 4b — metrics-server"
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  warn "metrics-server already installed"
else
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
    2>&1 | tail -3
  kubectl wait --for=condition=available deployment/metrics-server \
    -n kube-system --timeout=90s \
    || warn "metrics-server not ready yet — HPAs may lag on first deploy"
  success "metrics-server installed"
fi

# ── Step 5 — ArgoCD Image Updater ────────────────────────────────────────────
banner "STEP 5 — ArgoCD Image Updater"

# ECR credentials script — Image Updater calls this executable to get a token.
# It must be mounted into the pod at /usr/local/bin/argocd-image-updater-ecr-creds.
# Without this, Image Updater logs: "could not stat /usr/local/bin/..." and never
# pulls from ECR, so global.imageTag is never updated.
log "Applying ECR credentials ConfigMap..."
# ${ECR_CREDS_B64} is expanded by the outer BASTION_EOF heredoc to the literal
# base64 string computed on the local machine.  Decoding on the bastion produces
# a dynamic script that calls aws ecr get-login-password at runtime — tokens are
# never embedded statically and always fresh when Image Updater calls the script.
echo "${ECR_CREDS_B64}" | base64 -d > /tmp/ecr-creds.sh
chmod +x /tmp/ecr-creds.sh
kubectl create configmap ecr-creds-script \
  --from-file=ecr-creds=/tmp/ecr-creds.sh \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -
success "ECR credentials ConfigMap applied"

# helm upgrade --install is idempotent: installs on first run, upgrades on re-runs.
# The chart uses "volumes" / "volumeMounts" (not extraVolumes/extraVolumeMounts).
# defaultMode 493 = octal 0755 (executable).
# Passing complex arrays via --set doesn't work reliably for nested objects,
# so we write a values file and use -f instead.
cat > /tmp/iu-helm-values.yaml << IUEOF
volumes:
  - name: ecr-creds-script
    configMap:
      name: ecr-creds-script
      defaultMode: 493
volumeMounts:
  - name: ecr-creds-script
    mountPath: /usr/local/bin/argocd-image-updater-ecr-creds
    subPath: ecr-creds
IUEOF

helm upgrade --install argocd-image-updater argocd-image-updater \
  --repo https://argoproj.github.io/argo-helm \
  --namespace argocd \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="\$IMAGE_UPDATER_ROLE" \
  --set "config.registries[0].name=ECR" \
  --set "config.registries[0].api_url=https://\${ACCOUNT}.dkr.ecr.\${REGION}.amazonaws.com" \
  --set "config.registries[0].prefix=\${ACCOUNT}.dkr.ecr.\${REGION}.amazonaws.com" \
  --set "config.registries[0].credentials=ext:/usr/local/bin/argocd-image-updater-ecr-creds" \
  --set "config.registries[0].credsexpire=10h" \
  -f /tmp/iu-helm-values.yaml \
  --version 0.9.6 \
  --wait --timeout 5m 2>&1 | tail -5
success "Image Updater installed with ECR credentials volume mount"

# ── Step 6 — Apply ArgoCD Application manifests ──────────────────────────────
banner "STEP 6 — ArgoCD Application manifests"
kubectl get ns argocd &>/dev/null \
  || err "argocd namespace missing — ArgoCD must be installed first"

cat <<'APPEOF' | kubectl apply -f -
${APP_MANIFEST}
APPEOF
success "payflow Application applied"

cat <<'MONEOF' | kubectl apply -f -
${MON_MANIFEST}
MONEOF
success "payflow-monitoring Application applied"

# Set global.imageTag to the latest tag already in ECR so ArgoCD never tries
# to pull a ":latest" tag (which doesn't exist).  Image Updater will keep this
# updated automatically on every subsequent CI push.
log "Detecting latest api-gateway tag from ECR..."
LATEST_TAG=\$(aws ecr describe-images \
  --repository-name "\${CLUSTER_NAME}/api-gateway" \
  --region "\$REGION" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text 2>/dev/null || echo "")
if [ -n "\$LATEST_TAG" ] && [ "\$LATEST_TAG" != "None" ]; then
  log "Setting global.imageTag → \$LATEST_TAG"
  kubectl patch application payflow -n argocd --type merge -p \
    "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"global.imageTag\",\"value\":\"\$LATEST_TAG\"}]}}}}" \
    || warn "Could not patch global.imageTag — ArgoCD may not be ready yet"
  success "global.imageTag set to \$LATEST_TAG"
else
  warn "No ECR images found yet — global.imageTag NOT set."
  warn "Image Updater CANNOT bootstrap the tag from zero running pods (chicken-and-egg):"
  warn "  it derives the tracked image from a running container, but no container can"
  warn "  start until the tag is set. Result: the first sync deadlocks on the migration hook."
  warn "FIX — run CI BEFORE setup-cluster on a fresh spinup so ECR has images:"
  warn "  correct order:  spinup.sh  ->  push to main (CI builds images)  ->  setup-cluster.sh"
  warn "RECOVER (if you already ran setup-cluster with empty ECR): after CI is green, run:"
  warn "  kubectl patch application payflow -n argocd --type merge \\\\"
  warn "    -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"global.imageTag\",\"value\":\"<LATEST_ECR_TAG>\"}]}}}}'"
fi

# ── Step 7 — Wait for ArgoCD sync ────────────────────────────────────────────
banner "STEP 7 — Waiting for ArgoCD sync (up to 10 min)"
DEGRADE_COUNT=0
for i in \$(seq 1 40); do
  HEALTH=\$(kubectl get application payflow -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  SYNC=\$(kubectl get application payflow -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  printf "  [%02d/40] health: %-10s  sync: %s\n" "\$i" "\$HEALTH" "\$SYNC"
  [ "\$HEALTH" = "Healthy" ] && break
  if [ "\$HEALTH" = "Degraded" ]; then
    DEGRADE_COUNT=\$((DEGRADE_COUNT + 1))
    if [ "\$DEGRADE_COUNT" -ge 5 ]; then
      warn "App has been Degraded for 5+ checks — check ArgoCD UI or run:"
      warn "  kubectl get events -n payflow --sort-by=.lastTimestamp | tail -20"
    fi
  else
    DEGRADE_COUNT=0
  fi
  sleep 15
done

# ── Summary ──────────────────────────────────────────────────────────────────
banner "SETUP COMPLETE"
PF_HEALTH=\$(kubectl get application payflow -n argocd \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
MON_HEALTH=\$(kubectl get application payflow-monitoring -n argocd \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
ARGOCD_NLB=\$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
ARGOCD_PASS=\$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<check manually>")

echo ""
echo "  payflow app health:        \$PF_HEALTH"
echo "  payflow-monitoring health: \$MON_HEALTH"
echo ""
echo "  ArgoCD NLB (VPC-only):     https://\$ARGOCD_NLB"
echo "  ArgoCD admin password:     \$ARGOCD_PASS"
echo ""
echo "  NEXT STEPS (see QUICK-START-INFRA.md Post-Setup Steps A-D):"
echo "  A. Update WAF ARN: cd terraform/aws/spoke-vpc-eks && terraform output -raw waf_web_acl_arn"
echo "     → update helm/payflow/values-dev.yaml ingress.wafArn, commit + push"
echo "  B. Generate webhook secret (on bastion): openssl rand -hex 32"
echo "     → aws secretsmanager update-secret --secret-id payflow/dev/github-webhook-secret ..."
echo "  C. Register GitHub webhook: get URL from terraform output argocd_webhook_url"
echo "     → gh api repos/<owner>/<repo>/hooks -f name=web -f config[url]=<URL>/webhook ..."
echo "  D. ArgoCD token: patch argocd-cm apiKey capability → generate token in UI"
echo "     → store in Secrets Manager: payflow/dev/argocd-token + payflow/dev/argocd-internal-url"
BASTION_EOF

success "Bastion script generated ($(wc -l < "$BASTION_SCRIPT") lines)"

# =============================================================================
# PART 4 — UPLOAD TO S3 + PRESIGNED URL
# =============================================================================
banner "UPLOADING SCRIPT TO S3"

S3_KEY="setup-scripts/bastion_setup_$(date +%Y%m%d_%H%M%S).sh"
log "Uploading to s3://$TFSTATE_BUCKET/$S3_KEY..."
aws s3 cp "$BASTION_SCRIPT" "s3://${TFSTATE_BUCKET}/${S3_KEY}" --region "$REGION"

log "Generating presigned URL (valid 30 minutes)..."
PRESIGNED_URL=$(aws s3 presign "s3://${TFSTATE_BUCKET}/${S3_KEY}" \
  --expires-in 1800 --region "$REGION")
success "Script available via presigned URL"

# =============================================================================
# PART 5 — SSM RUN COMMAND
# =============================================================================
banner "RUNNING SETUP ON BASTION VIA SSM"

cat > "$PARAMS_FILE" << PARAMS_EOF
{
  "commands": [
    "curl -fsSL '${PRESIGNED_URL}' -o /tmp/bastion_cluster_setup.sh && chmod +x /tmp/bastion_cluster_setup.sh && /tmp/bastion_cluster_setup.sh 2>&1"
  ]
}
PARAMS_EOF

log "Sending SSM Run Command to $BASTION_ID..."
CMD_ID=$(aws ssm send-command \
  --instance-ids "$BASTION_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "file://${PARAMS_FILE}" \
  --timeout-seconds 1200 \
  --region "$REGION" \
  --query "Command.CommandId" \
  --output text)
success "Command ID: $CMD_ID"

log "Polling for completion (up to 20 minutes)..."
echo ""
ELAPSED=0
STATUS="InProgress"
while [ "$ELAPSED" -lt 1200 ]; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$BASTION_ID" \
    --query "Status" \
    --output text --region "$REGION" 2>/dev/null || echo "Pending")
  printf "\r  Status: %-20s (%ds elapsed)" "$STATUS" "$ELAPSED"
  case "$STATUS" in
    Success|Failed|TimedOut|Cancelled|Undeliverable) break ;;
  esac
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done
echo ""

# =============================================================================
# PART 6 — PRINT BASTION OUTPUT
# =============================================================================
banner "BASTION OUTPUT"

STDOUT=$(aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$BASTION_ID" \
  --query "StandardOutputContent" \
  --output text --region "$REGION" 2>/dev/null || echo "<unable to retrieve output>")
STDERR=$(aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$BASTION_ID" \
  --query "StandardErrorContent" \
  --output text --region "$REGION" 2>/dev/null || echo "")
EXIT_CODE=$(aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$BASTION_ID" \
  --query "ResponseCode" \
  --output text --region "$REGION" 2>/dev/null || echo "-1")

echo "$STDOUT"

if [ -n "$STDERR" ] && [ "$STDERR" != "None" ]; then
  echo ""
  echo -e "${YELLOW}--- stderr ---${NC}"
  echo "$STDERR"
fi

# Clean up the S3 script object
aws s3 rm "s3://${TFSTATE_BUCKET}/${S3_KEY}" --region "$REGION" 2>/dev/null || true

echo ""
if [ "$STATUS" = "Success" ] && [ "$EXIT_CODE" = "0" ]; then
  success "Cluster setup complete (exit 0)"
  echo ""
  echo -e "  ${YELLOW}NOTE: ArgoCD output above is limited to 24KB. If output was truncated:${NC}"
  echo -e "  ${YELLOW}  SSM into bastion and run: kubectl get pods -n payflow${NC}"
  echo -e "  ${YELLOW}  aws ssm start-session --target $BASTION_ID --region $REGION${NC}"
else
  error "Setup finished with status=$STATUS exit_code=$EXIT_CODE. Review output above."
fi
