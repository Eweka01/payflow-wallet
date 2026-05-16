# ──────────────────────────────────────────────────────────────
# VPC Endpoints — keep ECR, S3, and STS traffic inside AWS network
# Without these, nodes use NAT → internet → ECR/S3/STS (slower, costs more, one failure point)
# ──────────────────────────────────────────────────────────────

# S3 Gateway Endpoint (FREE — ECR image layers are stored in S3)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.eks.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.eks_private[*].id,
    aws_route_table.eks_public[*].id
  )

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-s3-endpoint"
    module    = "spoke-vpc-eks"
    Component = "vpc-endpoint"
  })
}

# Security group for interface endpoints (ECR, STS, Secrets Manager)
resource "aws_security_group" "vpc_endpoints" {
  # checkov:skip=CKV_AWS_382:VPC endpoints require unrestricted egress for health checks and endpoint responses
  name_prefix = "${local.name_prefix}-endpoints-sg-"
  description = "Allow HTTPS from EKS nodes to VPC interface endpoints"
  vpc_id      = aws_vpc.eks.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    description     = "HTTPS from EKS nodes"
  }

  egress {
    description = "Outbound for VPC endpoint health checks and responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoints-sg"
  })
}

# ECR API endpoint (for GetAuthorizationToken, GetDownloadUrlForLayer)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.eks.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.eks_private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-ecr-api-endpoint"
    module    = "spoke-vpc-eks"
    Component = "vpc-endpoint"
  })
}

# ECR DKR endpoint (for Docker image layer pulls)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.eks.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.eks_private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-ecr-dkr-endpoint"
    module    = "spoke-vpc-eks"
    Component = "vpc-endpoint"
  })
}

# STS endpoint (for IRSA token exchange — ESO, ALB controller, cluster autoscaler)
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.eks.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.eks_private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-sts-endpoint"
    module    = "spoke-vpc-eks"
    Component = "vpc-endpoint"
  })
}

# Secrets Manager endpoint (for ESO → Secrets Manager without NAT)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.eks.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.eks_private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-secretsmanager-endpoint"
    module    = "spoke-vpc-eks"
    Component = "vpc-endpoint"
  })
}
