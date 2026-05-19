locals {
  # env must come from var.environment, not terraform.workspace.
  # spinup.sh uses the default workspace, so terraform.workspace = "default"
  # which would tag all hub resources with environment = "default".
  env = var.environment

  common_tags = {
    project       = "payflow"
    environment   = local.env
    team          = "engineering"
    owner         = "engineering"
    "cost-center" = "ENG-001"
    "managed-by"  = "terraform"
    module        = "hub-vpc"
  }
}

