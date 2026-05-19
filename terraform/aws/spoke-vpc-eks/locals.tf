# Local values for environment-based configuration
# env is driven by var.environment (set in terraform.tfvars) NOT by terraform workspace.
# spinup.sh always uses the default workspace; using terraform.workspace here would set
# local.env = "default", causing Secrets Manager paths like payflow/default/rds that
# ESO (configured for payflow/dev/...) cannot find. var.environment fixes this.

locals {
  env = var.environment

  # Node configuration per environment
  node_config = {
    dev = {
      desired_size    = 2   # 2 nodes needed: 6 services × minReplicas 2 × 250m = 3000m > 1 node
      min_size        = 1   # CA can scale down to 1 during idle
      max_size        = 3
      instance_type   = "t3.large"  # t3.medium (2vCPU) runs out with 6 services + system pods
      capacity_type   = "SPOT"  # Save money in dev
    }
    staging = {
      desired_size    = 2
      min_size        = 1
      max_size        = 3
      instance_type   = "t3.medium"
      capacity_type   = "ON_DEMAND"
    }
    prod = {
      desired_size    = 3
      min_size        = 2
      max_size        = 10
      instance_type   = "t3.large"
      capacity_type   = "ON_DEMAND"
    }
    # Default fallback (if workspace not in list)
    default = {
      desired_size    = 2
      min_size        = 1
      max_size        = 5
      instance_type   = "t3.medium"
      capacity_type   = "ON_DEMAND"
    }
  }

  # Get current environment config (with fallback)
  current_node_config = lookup(local.node_config, local.env, local.node_config["default"])

  # Naming prefix includes environment
  name_prefix = "${var.eks_cluster_name}-${local.env}"

  # Common tags for all resources (FinOps). Use single canonical keys only;
  # IAM treats tag keys as case-insensitive, so avoid Project+project etc.
  common_tags = {
    project       = var.project_name
    environment   = local.env
    team          = var.team
    owner         = var.owner
    "cost-center" = var.cost_center
    "managed-by"  = "terraform"
    module        = "spoke-vpc-eks"
  }
}

