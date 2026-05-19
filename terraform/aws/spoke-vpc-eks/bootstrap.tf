# Bootstrap node: runs inside VPC via SSM only. No kubernetes/helm providers.
# Ordering: instance is created only after cluster, node group, and addons are ACTIVE.

module "bootstrap_node" {
  source = "./modules/bootstrap-node"

  name_prefix  = local.name_prefix
  vpc_id        = aws_vpc.eks.id
  subnet_id     = aws_subnet.eks_private[0].id
  cluster_name       = aws_eks_cluster.payflow.name
  aws_region         = var.aws_region
  kubernetes_version = var.kubernetes_version

  node_role_arn                = aws_iam_role.eks_node.arn
  admin_iam_users              = var.admin_iam_users
  account_id                   = data.aws_caller_identity.current.account_id

  alb_irsa_arn                 = aws_iam_role.alb_controller_irsa.arn
  external_secrets_irsa_arn    = aws_iam_role.external_secrets_irsa.arn
  cluster_autoscaler_irsa_arn  = aws_iam_role.cluster_autoscaler_irsa.arn
  image_updater_irsa_arn       = aws_iam_role.image_updater_irsa.arn
  enable_external_dns          = var.enable_external_dns
  external_dns_irsa_arn        = var.enable_external_dns ? aws_iam_role.external_dns_irsa.arn : ""
  domain_name                  = var.domain_name

  # If bootstrap fails (e.g. helm --wait times out, IRSA not propagated, spot interruption),
  # the instance exits non-zero and stays running. Terraform will not create a new one on
  # re-apply. Ingress will stay Pending. Fix: terminate this instance in EC2, then terraform
  # apply again. See docs/BOOTSTRAP-TROUBLESHOOTING.md.
  self_terminate = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bootstrap"
  })

  depends_on = [
    aws_eks_cluster.payflow,
    aws_eks_node_group.on_demand,
    aws_eks_addon.coredns,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.ebs_csi,
    time_sleep.wait_for_irsa, # IRSA must propagate before ALB/ESO pods start
  ]
}
