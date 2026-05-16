#!/usr/bin/env bash
# =============================================================================
# PayFlow Cluster Setup Script
# =============================================================================
# Runs AFTER spinup.sh has completed all Terraform infrastructure.
# Installs ArgoCD, ESO, metrics-server, then applies the ArgoCD Application
# manifests so the full payflow app and monitoring stack deploy automatically.
#
# Run from your LOCAL machine (not the bastion).
# Requires: aws CLI configured, kubectl, helm
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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pre-flight ────────────────────────────────────────────────────────────────
banner "PRE-FLIGHT CHECKS"

command -v aws      > /dev/null 2>&1 || error "aws CLI not found. Install: brew install awscli"
command -v kubectl  > /dev/null 2>&1 || error "kubectl not found. Install: brew install kubectl"
command -v helm     > /dev/null 2>&1 || error "helm not found. Install: brew install helm"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
  || error "AWS CLI not configured. Run: aws configure"
success "AWS account: $ACCOUNT  region: $REGION"

# Check EKS cluster is ACTIVE
CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.status' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
[ "$CLUSTER_STATUS" = "ACTIVE" ] || error "EKS cluster '$CLUSTER_NAME' is not ACTIVE (status: $CLUSTER_STATUS). Run spinup.sh first."
success "EKS cluster: $CLUSTER_NAME ($CLUSTER_STATUS)"

# ── Step 1 — Configure kubeconfig ────────────────────────────────────────────
banner "STEP 1 — Configure kubeconfig"

log "Updating kubeconfig for cluster $CLUSTER_NAME..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --no-cli-pager

# Verify cluster connectivity
log "Verifying kubectl connectivity..."
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
if [ "$NODE_COUNT" -eq 0 ]; then
  warn "No Ready nodes found yet. Waiting up to 3 minutes for nodes to join..."
  for i in $(seq 1 18); do
    sleep 10
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    [ "$NODE_COUNT" -gt 0 ] && break
    log "  Waiting... ($((i*10))s)"
  done
fi
[ "$NODE_COUNT" -gt 0 ] || error "No Ready nodes after 3 minutes. Check EKS node group in AWS console."
success "$NODE_COUNT node(s) Ready"
kubectl get nodes

# ── Step 2 — Install ArgoCD ───────────────────────────────────────────────────
banner "STEP 2 — Install ArgoCD"

if [ "$SKIP_ARGOCD" = true ]; then
  warn "--skip-argocd set. Skipping ArgoCD install."
else
  # Check if already installed
  if kubectl get namespace argocd > /dev/null 2>&1 && \
     kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>/dev/null | grep -q "Running"; then
    warn "ArgoCD already running. Skipping install. Use --skip-argocd to silence this."
  else
    log "Creating argocd namespace..."
    kubectl create namespace argocd 2>/dev/null || true

    log "Installing ArgoCD (server-side apply — required for large CRDs)..."
    # --server-side is required: ArgoCD CRDs exceed the 262KB annotation size limit
    # that standard kubectl apply uses for last-applied-configuration.
    kubectl apply --server-side -f \
      https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
      -n argocd

    log "Waiting for ArgoCD server to be ready (up to 3 minutes)..."
    kubectl wait --for=condition=available deployment/argocd-server \
      -n argocd --timeout=180s
    success "ArgoCD deployed"
  fi

  # Expose ArgoCD via LoadBalancer if not already
  ARGOCD_TYPE=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
  if [ "$ARGOCD_TYPE" != "LoadBalancer" ]; then
    log "Exposing ArgoCD server via LoadBalancer..."
    kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
  fi

  log "Waiting for ArgoCD LoadBalancer external IP (up to 2 minutes)..."
  for i in $(seq 1 24); do
    ARGOCD_URL=$(kubectl get svc argocd-server -n argocd \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [ -n "$ARGOCD_URL" ] && break
    sleep 5
    log "  Waiting for NLB... ($((i*5))s)"
  done

  if [ -n "$ARGOCD_URL" ]; then
    success "ArgoCD UI: http://$ARGOCD_URL"
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<check manually>")
    success "ArgoCD admin password: $ARGOCD_PASSWORD"
    echo ""
    echo -e "  ${YELLOW}Save these credentials — you'll need them to log into the ArgoCD UI:${NC}"
    echo -e "  URL:      http://$ARGOCD_URL"
    echo -e "  User:     admin"
    echo -e "  Password: $ARGOCD_PASSWORD"
    echo ""
  else
    warn "ArgoCD NLB URL not yet assigned. Check: kubectl get svc argocd-server -n argocd"
  fi
fi

# ── Step 3 — Install External Secrets Operator (ESO) ─────────────────────────
banner "STEP 3 — Install External Secrets Operator"

if [ "$SKIP_ESO" = true ]; then
  warn "--skip-eso set. Skipping ESO install."
else
  if kubectl get namespace external-secrets > /dev/null 2>&1 && \
     kubectl get pods -n external-secrets 2>/dev/null | grep -q "Running"; then
    warn "ESO already running. Skipping install."
  else
    # Derive the IRSA role ARN from account ID (matches Terraform module output)
    ESO_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/payflow-eks-cluster-external-secrets-irsa"

    # Verify the role exists before installing
    aws iam get-role --role-name payflow-eks-cluster-external-secrets-irsa \
      --region "$REGION" > /dev/null 2>&1 \
      || error "IRSA role not found: payflow-eks-cluster-external-secrets-irsa. Run spinup.sh first."

    log "Adding external-secrets Helm repo..."
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo update

    log "Installing External Secrets Operator..."
    helm install external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --create-namespace \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ESO_ROLE_ARN" \
      --wait \
      --timeout 3m

    success "ESO installed with IRSA role: $ESO_ROLE_ARN"
  fi
fi

# ── Step 4 — Install metrics-server ──────────────────────────────────────────
banner "STEP 4 — Install metrics-server"

if kubectl get deployment metrics-server -n kube-system > /dev/null 2>&1; then
  warn "metrics-server already installed. Skipping."
else
  log "Installing metrics-server (required for HPA)..."
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

  log "Waiting for metrics-server to be ready (up to 90 seconds)..."
  kubectl wait --for=condition=available deployment/metrics-server \
    -n kube-system --timeout=90s || warn "metrics-server not ready yet — HPAs may not work immediately"
  success "metrics-server installed"
fi

# ── Step 5 — Apply ArgoCD Application manifests ───────────────────────────────
banner "STEP 5 — Apply ArgoCD Application manifests"

# Verify ArgoCD is running before applying Applications
kubectl get namespace argocd > /dev/null 2>&1 \
  || error "ArgoCD namespace not found. ArgoCD must be installed before applying Applications."

log "Applying payflow Application (Helm chart → payflow namespace)..."
kubectl apply -f "$REPO_ROOT/helm/argocd/application.yaml" -n argocd
success "payflow Application created"

log "Applying payflow-monitoring Application (raw YAML → monitoring namespace)..."
kubectl apply -f "$REPO_ROOT/helm/argocd/monitoring-application.yaml" -n argocd
success "payflow-monitoring Application created"

# ── Step 6 — Wait for sync and report ────────────────────────────────────────
banner "STEP 6 — Waiting for ArgoCD to sync"

log "ArgoCD will now pull from GitHub and deploy everything."
log "This typically takes 3-5 minutes for initial sync."
log "Waiting up to 10 minutes for payflow app to become Healthy..."
echo ""

for i in $(seq 1 40); do
  HEALTH=$(kubectl get application payflow -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  SYNC=$(kubectl get application payflow -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  echo -e "  [${i}/40] payflow → health: ${HEALTH}  sync: ${SYNC}"
  [ "$HEALTH" = "Healthy" ] && break
  sleep 15
done

echo ""
PAYFLOW_HEALTH=$(kubectl get application payflow -n argocd \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
MONITORING_HEALTH=$(kubectl get application payflow-monitoring -n argocd \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

if [ "$PAYFLOW_HEALTH" = "Healthy" ]; then
  success "payflow app: Healthy"
else
  warn "payflow app: $PAYFLOW_HEALTH (may still be syncing — check ArgoCD UI)"
fi
echo -e "  payflow-monitoring: $MONITORING_HEALTH"

# ── Summary ───────────────────────────────────────────────────────────────────
banner "SETUP COMPLETE — SUMMARY"

FRONTEND_URL=$(kubectl get svc frontend -n payflow \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
ARGOCD_URL_FINAL=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<unavailable>")

echo ""
echo -e "  ${GREEN}${BOLD}PayFlow Application:${NC}"
echo -e "    URL: http://$FRONTEND_URL"
echo ""
echo -e "  ${GREEN}${BOLD}ArgoCD UI:${NC}"
echo -e "    URL:      http://$ARGOCD_URL_FINAL"
echo -e "    User:     admin"
echo -e "    Password: $ARGOCD_PASS"
echo ""
echo -e "  ${GREEN}${BOLD}Useful commands:${NC}"
echo -e "    kubectl get pods -n payflow"
echo -e "    kubectl get application -n argocd"
echo -e "    kubectl get pods -n monitoring"
echo ""
echo -e "  ${YELLOW}Note:${NC} If frontend URL shows <pending>, wait 1-2 minutes for the NLB"
echo -e "  to be assigned, then run: kubectl get svc frontend -n payflow"
echo ""
