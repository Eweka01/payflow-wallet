# Hub VPC - Centralized Network Services
# This VPC contains shared services like Bastion, VPN Gateway, and Transit Gateway

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Hub VPC
resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name   = "payflow-hub-vpc"
    module = "hub-vpc"
  })
}

# Internet Gateway for Hub VPC
resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-igw"
    module    = "hub-vpc"
    Component = "internet-gateway"
  })
}

# Public Subnet for Bastion
resource "aws_subnet" "hub_public" {
  # checkov:skip=CKV_AWS_130:Public subnet requires map_public_ip_on_launch for bastion host and NAT gateway functionality
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = var.hub_public_subnet_cidr
  availability_zone        = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                        = "payflow-hub-public-subnet"
    "kubernetes.io/role/elb"    = "1"
    module                      = "hub-vpc"
    Component                   = "public-subnet"
  })
}

# Private Subnet for Shared Services
resource "aws_subnet" "hub_private" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-private-subnet"
    module    = "hub-vpc"
    Component = "private-subnet"
  })
}

# Route Table for Public Subnet
# NOTE: Both routes must be inline — mixing inline routes with aws_route resources
# causes Terraform to treat inline as authoritative and delete standalone routes on every apply.
resource "aws_route_table" "hub_public" {
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }

  route {
    cidr_block         = var.spoke_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-public-rt"
    module    = "hub-vpc"
    Component = "route-table-public"
  })

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "hub_public" {
  subnet_id      = aws_subnet.hub_public.id
  route_table_id = aws_route_table.hub_public.id
}

# Route Table for Private Subnet
resource "aws_route_table" "hub_private" {
  vpc_id = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-private-rt"
    module    = "hub-vpc"
    Component = "route-table-private"
  })
}

resource "aws_route_table_association" "hub_private" {
  subnet_id      = aws_subnet.hub_private.id
  route_table_id = aws_route_table.hub_private.id
}

# Transit Gateway for Hub-and-Spoke connectivity
resource "aws_ec2_transit_gateway" "hub" {
  description                     = "PayFlow Hub Transit Gateway"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-tgw"
    module    = "hub-vpc"
    Component = "tgw"
  })
}

# Transit Gateway Attachment for Hub VPC (both subnets so bastion in public AZ can reach TGW)
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  subnet_ids         = [aws_subnet.hub_public.id, aws_subnet.hub_private.id]
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name      = "payflow-hub-tgw-attachment"
    module    = "hub-vpc"
    Component = "tgw-attachment"
  })
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

