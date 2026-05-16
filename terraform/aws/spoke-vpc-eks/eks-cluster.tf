# EKS Cluster Configuration

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster" {
  name = "payflow-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name   = "payflow-eks-cluster-role"
    module = "spoke-vpc-eks"
  })
}

# Attach EKS Cluster Policy
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# Wait for IAM to propagate (AWS eventually consistent)
resource "time_sleep" "wait_for_cluster_iam" {
  depends_on = [
    aws_iam_role.eks_cluster,
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
  create_duration = "60s"   # was 20s
}

# KMS Key for EKS Encryption
resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS cluster encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true  # Required for PCI-DSS compliance

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-kms-key"
    module    = "spoke-vpc-eks"
    Component = "kms-eks"
  })
}

# EKS Cluster
resource "aws_eks_cluster" "payflow" {
  name     = var.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.eks_private[*].id, aws_subnet.eks_public[*].id)  # Both private and public for ALB
    endpoint_private_access = true
    endpoint_public_access  = false # Private endpoint only, access via Bastion
  }

  # Allow nodes to join via EKS Access Entries
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # Timeouts for slow operations
  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }

  # Lifecycle: prod workspace blocks destroy; access_config ignored so CLI-set values do not force replace
  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      tags,
      enabled_cluster_log_types,
      access_config,
    ]
  }

  depends_on = [
    time_sleep.wait_for_cluster_iam,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks,
  ]

  tags = merge(local.common_tags, {
    Name      = var.eks_cluster_name
    module    = "spoke-vpc-eks"
    Component = "eks-cluster"
  })
}

# CloudWatch Log Group for EKS
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = 365  # 1 year minimum for fintech compliance

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-cluster-logs"
    module    = "spoke-vpc-eks"
    Component = "cloudwatch-logs"
  })
}

# Wait for cluster to be fully ready before proceeding
resource "time_sleep" "wait_for_cluster" {
  depends_on = [aws_eks_cluster.payflow]
  create_duration = "60s"   # was 30s
}

# Wait for OIDC to be ready
resource "time_sleep" "wait_for_oidc" {
  depends_on = [aws_iam_openid_connect_provider.eks]
  create_duration = "30s"   # was 10s
}

# OIDC Provider for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.payflow.identity[0].oidc[0].issuer

  depends_on = [time_sleep.wait_for_cluster]
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url              = aws_eks_cluster.payflow.identity[0].oidc[0].issuer

  depends_on = [data.tls_certificate.eks]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-oidc-provider"
    module    = "spoke-vpc-eks"
    Component = "oidc-provider"
  })
}

# EKS Addon: VPC CNI (MUST be installed before nodes)
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.payflow.name
  addon_name               = "vpc-cni"
  service_account_role_arn = aws_iam_role.vpc_cni_irsa.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "20m"
    update = "20m"
    delete = "15m"
  }

  depends_on = [
    time_sleep.wait_for_cluster,
    time_sleep.wait_for_irsa,  # IRSA must be propagated
  ]
}

# EKS Addon: CoreDNS (depends on nodes)
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.payflow.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "30m"
    update = "30m"
    delete = "15m"
  }

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_node_group.on_demand,
  ]
}

# EKS Addon: kube-proxy (depends on nodes)
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.payflow.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "30m"
    update = "30m"
    delete = "15m"
  }

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_node_group.on_demand,
  ]
}

# EKS Addon: EBS CSI Driver (depends on nodes)
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.payflow.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "30m"
    update = "30m"
    delete = "15m"
  }

  depends_on = [
    aws_eks_node_group.on_demand,
    aws_eks_addon.vpc_cni,
    time_sleep.wait_for_irsa,
  ]
}

