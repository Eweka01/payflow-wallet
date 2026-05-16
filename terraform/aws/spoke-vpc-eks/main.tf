# Spoke VPC for EKS Cluster
# This VPC contains the EKS cluster and application workloads
# (required_providers are in backend.tf)

provider "aws" {
  region = var.aws_region
}

# Get Hub VPC (only when not using hub remote state; skip when hub_tfstate_bucket set or hub may be gone)
data "aws_vpc" "hub" {
  count = var.hub_tfstate_bucket != "" ? 0 : 1

  filter {
    name   = "tag:Name"
    values = ["payflow-hub-vpc"]
  }
}

# Only lookup by tags when not using hub remote state (avoids "multiple TGWs matched" when multiple exist).
data "aws_ec2_transit_gateway" "hub" {
  count = var.hub_tfstate_bucket != "" ? 0 : 1

  filter {
    name   = "tag:Name"
    values = ["payflow-hub-tgw"]
  }
  filter {
    name   = "tag:environment"
    values = [var.environment]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Spoke VPC for EKS
resource "aws_vpc" "eks" {
  cidr_block           = var.eks_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name   = "payflow-eks-vpc"
    module = "spoke-vpc-eks"
  })
}

# Public Subnets for NAT Gateway and ALB (across multiple AZs)
resource "aws_subnet" "eks_public" {
  # checkov:skip=CKV_AWS_130:Public subnets require map_public_ip_on_launch for NAT Gateway and ALB Ingress Controller functionality
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.eks.id
  cidr_block              = cidrsubnet(var.eks_vpc_cidr, 8, count.index + 10)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  timeouts {
    delete = "20m"
  }

  tags = merge(local.common_tags, {
    Name                               = "payflow-eks-public-subnet-${count.index + 1}"
    "kubernetes.io/role/elb"          = "1"  # Required for ALB
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  })
}

# Private Subnets for EKS (across multiple AZs)
resource "aws_subnet" "eks_private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.eks.id
  cidr_block        = cidrsubnet(var.eks_vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]

  timeouts {
    delete = "20m"
  }

  tags = merge(local.common_tags, {
    Name                               = "payflow-eks-private-subnet-${count.index + 1}"
    "kubernetes.io/role/internal-elb"  = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  })
}

# NAT Gateway for outbound internet (optional, for cost savings can be removed)
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? length(var.availability_zones) : 0

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name     = "payflow-eks-nat-eip-${count.index + 1}"
    module   = "spoke-vpc-eks"
    Component = "nat-eip"
  })
}

resource "aws_nat_gateway" "eks" {
  count = var.enable_nat_gateway ? length(var.availability_zones) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.eks_public[count.index].id  # NAT Gateway must be in public subnet

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-nat-${count.index + 1}"
    module    = "spoke-vpc-eks"
    Component = "nat-gateway"
  })

  depends_on = [aws_internet_gateway.eks]
}

# Internet Gateway (for NAT Gateway)
resource "aws_internet_gateway" "eks" {
  count = var.enable_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.eks.id

  timeouts {
    delete = "15m"
  }

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-igw"
    module    = "spoke-vpc-eks"
    Component = "internet-gateway"
  })
}

# Route Table for Public Subnets (always created so EKS API in public subnet can respond to bastion via TGW)
resource "aws_route_table" "eks_public" {
  count = length(var.availability_zones)

  vpc_id = aws_vpc.eks.id

  # Return path so EKS endpoint ENIs in public subnets can respond back to the hub VPC (bastion)
  dynamic "route" {
    for_each = local.transit_gateway_id != null ? [1] : []
    content {
      cidr_block         = var.hub_vpc_cidr
      transit_gateway_id = local.transit_gateway_id
    }
  }

  # Route to Internet Gateway only when NAT is enabled (for public internet / ALB)
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = one(aws_internet_gateway.eks).id
    }
  }

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-public-rt-${count.index + 1}"
    module    = "spoke-vpc-eks"
    Component = "route-table-public"
  })
}

resource "aws_route_table_association" "eks_public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.eks_public[count.index].id
  route_table_id = aws_route_table.eks_public[count.index].id
}

# Route Table for Private Subnets
resource "aws_route_table" "eks_private" {
  count = length(var.availability_zones)

  vpc_id = aws_vpc.eks.id

  # Route to Transit Gateway (for Hub connectivity — specific hub CIDR only)
  dynamic "route" {
    for_each = local.transit_gateway_id != null ? [1] : []
    content {
      cidr_block         = var.hub_vpc_cidr
      transit_gateway_id = local.transit_gateway_id
    }
  }

  # Route to NAT Gateway (for internet access)
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.eks[count.index].id
    }
  }

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-private-rt-${count.index + 1}"
    module    = "spoke-vpc-eks"
    Component = "route-table-private"
  })
}

resource "aws_route_table_association" "eks_private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.eks_private[count.index].id
  route_table_id = aws_route_table.eks_private[count.index].id
}

# Transit Gateway Attachment for Spoke VPC
# Use private subnets for Transit Gateway attachment.
# When hub state is missing (e.g. during teardown), count=0 so config is valid and Terraform can destroy the attachment from state.
resource "aws_ec2_transit_gateway_vpc_attachment" "eks" {
  count = local.transit_gateway_id != null ? 1 : 0

  subnet_ids         = aws_subnet.eks_private[*].id
  transit_gateway_id = local.transit_gateway_id
  vpc_id             = aws_vpc.eks.id

  tags = merge(local.common_tags, {
    Name      = "payflow-eks-tgw-attachment"
    module    = "spoke-vpc-eks"
    Component = "tgw-attachment"
  })
}

# Route in Hub VPC to reach Spoke VPC
resource "aws_route" "hub_to_eks" {
  count = local.hub_to_eks_route_count

  route_table_id         = local.hub_private_route_table_id
  destination_cidr_block = var.eks_vpc_cidr
  transit_gateway_id     = local.transit_gateway_id
}

# Get Hub private route table (only when not using hub remote state)
data "aws_route_table" "hub_private" {
  count = var.hub_tfstate_bucket != "" ? 0 : 1

  filter {
    name   = "tag:Name"
    values = ["payflow-hub-private-rt"]
  }
}

