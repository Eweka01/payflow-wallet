#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/bootstrap.log) 2>&1

CLUSTER_NAME="${cluster_name}"
AWS_REGION="${aws_region}"
VPC_ID="${vpc_id}"
NODE_ROLE_ARN="${node_role_arn}"
ACCOUNT_ID="${account_id}"
ADMIN_USERS='${admin_users_json}'
ALB_IRSA_ARN="${alb_irsa_arn}"
EXTERNAL_SECRETS_IRSA_ARN="${external_secrets_irsa_arn}"
CLUSTER_AUTOSCALER_IRSA_ARN="${cluster_autoscaler_irsa_arn}"
IMAGE_UPDATER_IRSA_ARN="${image_updater_irsa_arn}"
ENABLE_EXTERNAL_DNS="${enable_external_dns}"
EXTERNAL_DNS_IRSA_ARN="${external_dns_irsa_arn}"
DOMAIN_NAME="${domain_name}"
SELF_TERMINATE="${self_terminate}"

export AWS_DEFAULT_REGION="$AWS_REGION"

# --- Install kubectl (pinned to cluster version) ---
if ! command -v kubectl &>/dev/null; then
  RELEASE=$(curl -sL "https://dl.k8s.io/release/stable-${kubernetes_version}.txt" || echo "v${kubernetes_version}.0")
  curl -sLO "https://dl.k8s.io/release/$${RELEASE}/bin/linux/amd64/kubectl"
  chmod +x kubectl && mv kubectl /usr/local/bin/
fi

# --- Install Helm ---
if ! command -v helm &>/dev/null; then
  curl -sSfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- Ensure AWS CLI v2 and jq ---
if ! aws --version 2>/dev/null | grep -q "aws-cli/2"; then
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -b /usr/local/bin
fi
if ! command -v jq &>/dev/null; then
  curl -sSL -o /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 && chmod +x /usr/local/bin/jq
fi

# --- Kubeconfig ---
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# --- Wait for nodes (fail early if not Ready) ---
for i in $(seq 1 30); do
  if kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then
    echo "At least one node is Ready."
    break
  fi
  echo "Waiting for nodes... ($i/30)"
  sleep 20
done
if ! kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then
  echo "FATAL: No node reached Ready. Aborting bootstrap."
  exit 1
fi

# --- aws-auth ConfigMap (idempotent, YAML format) ---
cat > /tmp/aws-auth-roles.yaml <<EOF
- rolearn: $NODE_ROLE_ARN
  username: system:node:{{EC2PrivateDNSName}}
  groups:
    - system:bootstrappers
    - system:nodes
EOF

if [ -n "$ADMIN_USERS" ] && [ "$ADMIN_USERS" != "[]" ]; then
  echo "$ADMIN_USERS" | jq -r '.[] | "- userarn: arn:aws:iam::'"$ACCOUNT_ID"':user/\(.)\n  username: \(.)\n  groups:\n    - system:masters"' > /tmp/aws-auth-users.yaml
else
  echo "[]" > /tmp/aws-auth-users.yaml
fi

{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: aws-auth"
  echo "  namespace: kube-system"
  echo "data:"
  echo "  mapRoles: |"
  sed 's/^/    /' /tmp/aws-auth-roles.yaml
  echo "  mapUsers: |"
  sed 's/^/    /' /tmp/aws-auth-users.yaml
} | kubectl apply -f -

# --- Metrics Server ---
helm upgrade --install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server \
  --namespace kube-system \
  --set args[0]=--kubelet-insecure-tls \
  --version 3.11.0 \
  --wait --timeout 5m

# --- ALB Controller (1.10+ for k8s 1.31 compatibility) ---
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_IRSA_ARN" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --version 1.10.1 \
  --wait --timeout 5m

# --- External Secrets (replicaCount=1 so single-node dev works; scale up in prod if desired) ---
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install external-secrets external-secrets \
  --repo https://charts.external-secrets.io \
  --namespace external-secrets \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$EXTERNAL_SECRETS_IRSA_ARN" \
  --set replicaCount=1 \
  --version 0.10.4 \
  --wait --timeout 5m

# --- Cluster Autoscaler ---
helm upgrade --install cluster-autoscaler cluster-autoscaler \
  --repo https://kubernetes.github.io/autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$AWS_REGION" \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$CLUSTER_AUTOSCALER_IRSA_ARN" \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m \
  --set extraArgs.scale-down-utilization-threshold=0.5 \
  --version 9.38.0 \
  --wait --timeout 5m

# --- External DNS (optional) ---
if [ "$ENABLE_EXTERNAL_DNS" = "true" ] && [ -n "$EXTERNAL_DNS_IRSA_ARN" ] && [ -n "$DOMAIN_NAME" ]; then
  helm upgrade --install external-dns external-dns \
    --repo https://kubernetes-sigs.github.io/external-dns \
    --namespace kube-system \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$EXTERNAL_DNS_IRSA_ARN" \
    --set domainFilters[0]="$DOMAIN_NAME" \
    --set policy=sync \
    --set provider=aws \
    --version 1.13.0 \
    --wait --timeout 5m
fi

# --- ArgoCD Image Updater ---
# Watches ECR for new image tags. When a new tag appears, updates the ArgoCD
# Application parameter directly (no git write-back commit needed).
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd-image-updater argocd-image-updater \
  --repo https://argoproj.github.io/argo-helm \
  --namespace argocd \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$IMAGE_UPDATER_IRSA_ARN" \
  --set config.registries[0].name=ECR \
  --set config.registries[0].api_url="https://$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com" \
  --set config.registries[0].prefix="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com" \
  --set config.registries[0].credentials="ext:/usr/local/bin/argocd-image-updater-ecr-creds" \
  --set config.registries[0].credsexpire=10h \
  --version 0.9.6 \
  --wait --timeout 5m

echo "Bootstrap complete."

if [ "$SELF_TERMINATE" = "true" ]; then
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/instance-id")
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
fi
