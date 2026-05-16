# EKS Node Groups

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node" {
  name = "payflow-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name   = "payflow-eks-node-role"
    module = "spoke-vpc-eks"
  })
}

# Attach required policies
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node.name
}

# SSM Session Manager policy for node access (hub-and-spoke architecture)
resource "aws_iam_role_policy_attachment" "eks_node_ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node.name
}

# Wait for IAM to propagate (AWS eventually consistent)
resource "time_sleep" "wait_for_node_iam" {
  depends_on = [
    aws_iam_role.eks_node,
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
    aws_iam_role_policy_attachment.eks_node_ssm_policy,
  ]
  create_duration = "60s"   # was 20s
}

# Explicit node security group (deterministic wiring for private endpoint cluster)
# Avoids reliance on EKS auto-wiring which can fail during node group provisioning.
resource "aws_security_group" "eks_nodes" {
  # checkov:skip=CKV_AWS_382:EKS nodes require unrestricted egress to reach ECR, S3, Secrets Manager, and AWS APIs via VPC endpoints or internet
  name_prefix = "${local.name_prefix}-nodes-sg-"
  description = "Security group for EKS worker nodes (explicit control plane reachability)"
  vpc_id      = aws_vpc.eks.id

  egress {
    description = "All outbound — nodes need ECR, S3, Secrets Manager, AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nodes-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow nodes to reach the EKS control plane on 443 (kubelet TLS handshake)
resource "aws_security_group_rule" "cluster_from_nodes" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "EKS nodes to control plane (explicit wiring)"
}

# Allow bastion (Hub VPC) to reach EKS API on 443 for kubectl
resource "aws_security_group_rule" "cluster_from_hub" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.hub_vpc_cidr]
  description       = "Bastion (Hub VPC) to EKS API for kubectl"
}

# Minimal launch template: attach node SG + cluster SG (no AMI/user_data override)
resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${local.name_prefix}-lt-"
  description   = "EKS node group launch template with explicit SGs"

  vpc_security_group_ids = [
    aws_security_group.eks_nodes.id,
    aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id,
  ]

  # checkov:skip=CKV_AWS_341:hop_limit=2 is required for EKS pods to reach IMDS for IRSA token exchange; hop_limit=1 breaks pod identity
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 enforced — prevents SSRF-based credential theft
    http_put_response_hop_limit = 2           # 2 required for containerised workloads on EKS
  }

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-nodes-lt"
    module    = "spoke-vpc-eks"
    Component = "eks-launch-template"
  })

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_eks_cluster.payflow]
}

# On-Demand Node Group (for stateful services)
# ami_type = AL2023: required for EKS; AL2 support ends Nov 2025, no AL2 AMIs for K8s 1.33+
resource "aws_eks_node_group" "on_demand" {
  cluster_name    = aws_eks_cluster.payflow.name
  node_group_name = "payflow-${local.env}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.eks_private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = "$Latest"
  }

  scaling_config {
    desired_size = local.current_node_config.desired_size
    min_size     = local.current_node_config.min_size
    max_size     = local.current_node_config.max_size
  }

  instance_types = [local.current_node_config.instance_type]
  capacity_type  = local.current_node_config.capacity_type

  labels = {
    workload-type = "stateful"  # Single node group: all workloads run here (taint removed so stateless can schedule too)
  }

  update_config {
    max_unavailable = 1
  }

  # Timeouts for slow operations
  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  # Lifecycle: do NOT add create_before_destroy — node group name is fixed; replace must be destroy then create.
  # If replace still tries create-first and fails with "NodeGroup already exists", run:
  #   terraform destroy -target=aws_eks_node_group.on_demand
  #   terraform apply
  lifecycle {
    ignore_changes = [
      scaling_config[0].desired_size,
    ]
  }

  depends_on = [
    time_sleep.wait_for_node_iam,
    aws_eks_cluster.payflow,
    aws_eks_addon.vpc_cni,  # VPC CNI MUST be installed before nodes
    aws_launch_template.eks_nodes,
    aws_security_group_rule.cluster_from_nodes,  # Rule must exist before nodes join
  ]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-on-demand-nodes"
    module    = "spoke-vpc-eks"
    Component = "eks-node-group"
  })
}

# Spot node group removed: using on-demand only for dev/simpler ops.
# To re-enable, uncomment a new aws_eks_node_group.spot resource and add it back to depends_on in eks-cluster.tf and helm-addons.tf.

