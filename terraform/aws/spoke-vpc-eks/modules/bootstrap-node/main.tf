data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_iam_role" "bootstrap" {
  name = "${var.name_prefix}-bootstrap-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "bootstrap" {
  name = "${var.name_prefix}-bootstrap-policy"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster", "sts:GetCallerIdentity"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams"
          ]
          Resource = "arn:aws:logs:*:*:log-group:/payflow/bootstrap*"
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = "arn:aws:secretsmanager:*:*:secret:payflow/*"
        }
      ],
      var.self_terminate ? [
        {
          Effect   = "Allow"
          Action   = ["ec2:DescribeInstances", "ec2:TerminateInstances"]
          Resource = "*"
          Condition = {
            StringEquals = {
              "ec2:ResourceTag/Name" = "${var.name_prefix}-bootstrap"
            }
          }
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "${var.name_prefix}-bootstrap-profile"
  role = aws_iam_role.bootstrap.name
}

resource "aws_security_group" "bootstrap" {
  # checkov:skip=CKV_AWS_382:Bootstrap instance requires unrestricted egress to reach EKS API, ECR, SSM, and package repositories
  name_prefix = "${var.name_prefix}-bootstrap-sg-"
  description = "Bootstrap instance: egress only, SSM-only access"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound - SSM, EKS API, ECR, package repositories"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bootstrap-sg" })

  lifecycle { create_before_destroy = true }
}

locals {
  admin_users_json  = jsonencode(var.admin_iam_users)
  self_terminate    = var.self_terminate ? "true" : "false"
  enable_ext_dns    = var.enable_external_dns ? "true" : "false"
}

resource "aws_instance" "bootstrap" {
  # checkov:skip=CKV_AWS_135:EBS optimisation is always enabled on t3 instances by default; explicit flag not accepted by instance type
  # checkov:skip=CKV_AWS_126:Detailed EC2 monitoring adds cost not justified for a single-use bootstrap instance
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.micro"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.bootstrap.id]
  iam_instance_profile        = aws_iam_instance_profile.bootstrap.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  disable_api_termination = false

  root_block_device {
    encrypted = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.sh", {
    cluster_name                = var.cluster_name
    aws_region                  = var.aws_region
    kubernetes_version          = var.kubernetes_version
    vpc_id                      = var.vpc_id
    node_role_arn               = var.node_role_arn
    account_id                  = var.account_id
    admin_users_json            = local.admin_users_json
    alb_irsa_arn                = var.alb_irsa_arn
    external_secrets_irsa_arn   = var.external_secrets_irsa_arn
    cluster_autoscaler_irsa_arn = var.cluster_autoscaler_irsa_arn
    enable_external_dns         = local.enable_ext_dns
    external_dns_irsa_arn       = var.external_dns_irsa_arn
    domain_name                 = var.domain_name
    self_terminate              = local.self_terminate
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-bootstrap"
  })

  lifecycle {
    ignore_changes = [
      user_data,
      ami, # prevents replacement when new AMI releases
    ]
  }
}
