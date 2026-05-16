# Read Hub outputs from state so Spoke doesn't depend on Hub tag names.
# Set hub_tfstate_bucket to your state bucket (same as Hub module); use same workspace as Hub.

data "terraform_remote_state" "hub" {
  count   = var.hub_tfstate_bucket != "" ? 1 : 0
  backend = "s3"

  config = {
    bucket = var.hub_tfstate_bucket
    key    = "aws/hub-vpc/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  transit_gateway_id         = var.hub_tfstate_bucket != "" ? data.terraform_remote_state.hub[0].outputs.transit_gateway_id : data.aws_ec2_transit_gateway.hub[0].id
  hub_private_route_table_id  = var.hub_tfstate_bucket != "" ? data.terraform_remote_state.hub[0].outputs.hub_private_route_table_id : data.aws_route_table.hub_private[0].id
  hub_to_eks_route_count      = var.hub_tfstate_bucket != "" ? 1 : length(data.aws_vpc.hub[0].cidr_block_associations)
}
