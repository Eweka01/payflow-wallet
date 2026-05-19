# EKS security groups: resolved from AWS API so we never use stale IDs from remote state
# (stale state caused "security group does not exist" when spoke was re-applied and SGs changed)

# Shared VPC and subnet lookups used by all service resources in this module
data "aws_vpc" "eks" {
  filter {
    name   = "tag:Name"
    values = ["payflow-eks-vpc"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_subnets" "eks_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.eks.id]
  }
  filter {
    name   = "tag:Name"
    values = ["payflow-eks-private-subnet-*"]
  }
}

# Resolve EKS SGs by tag/name only — never use IDs from API or state (can be stale after SG replace)
# Cluster SG: EKS tags it with aws:eks:cluster-name
data "aws_security_groups" "eks_cluster_sg" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.eks.id]
  }
  filter {
    name   = "tag:aws:eks:cluster-name"
    values = ["payflow-eks-cluster"]
  }
}

# Node SG: spoke creates with tag Name = "payflow-eks-cluster-<env>-nodes-sg"
data "aws_security_groups" "eks_nodes" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.eks.id]
  }
  filter {
    name   = "tag:Name"
    values = ["payflow-eks-cluster-${local.env}-nodes-sg"]
  }
}

locals {
  # env comes from var.environment (set in terraform.tfvars), NOT terraform.workspace.
  # spoke-vpc-eks also uses var.environment for secret paths and SG naming.
  # Using terraform.workspace would give "default" with spinup.sh, breaking secret
  # path alignment (payflow/default/... vs payflow/dev/...) and SG tag lookups.
  env = var.environment
  # Only use SG IDs that exist in AWS (lookup by tag); never use API/state IDs that may be stale
  eks_sg_id      = length(data.aws_security_groups.eks_cluster_sg.ids) > 0 ? data.aws_security_groups.eks_cluster_sg.ids[0] : null
  eks_node_sg_id = length(data.aws_security_groups.eks_nodes.ids) > 0 ? data.aws_security_groups.eks_nodes.ids[0] : null
  # Drop any known-deleted SG IDs (e.g. from old tfvars or saved plan); only use tag-resolved + safe additional
  safe_additional_sgs = [for id in coalesce(var.additional_rds_security_group_ids, []) : id if id != "sg-002b656a4c951333b"]
  # Both cluster and node SGs so pod traffic (which egresses with node SG) can reach RDS, Redis, MQ
  rds_allowed_sgs = distinct(
    compact(
      concat(
        local.eks_sg_id != null ? [local.eks_sg_id] : [],
        local.eks_node_sg_id != null ? [local.eks_node_sg_id] : [],
        local.safe_additional_sgs
      )
    )
  )
}
