# Bastion Host - Secure Access Point for EKS/AKS

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

# Get Hub VPC data
data "aws_vpc" "hub" {
  filter {
    name   = "tag:Name"
    values = ["payflow-hub-vpc"]
  }
}

data "aws_subnet" "hub_public" {
  filter {
    name   = "tag:Name"
    values = ["payflow-hub-public-subnet"]
  }
}

# Security Group for Bastion
resource "aws_security_group" "bastion" {
  # checkov:skip=CKV_AWS_24:SSH ingress is restricted to var.authorized_ssh_cidrs defined in terraform.tfvars; not open to 0.0.0.0/0 in practice
  name        = "payflow-bastion-sg"
  description = "Security group for Bastion host"
  vpc_id      = data.aws_vpc.hub.id

  # SSH access from authorized IPs only
  ingress {
    description = "SSH from authorized IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.authorized_ssh_cidrs
  }

  # HTTPS to EKS API (Spoke), AWS SSM, and package repos
  egress {
    description = "HTTPS to EKS and SSM"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP for apt/package mirrors (Ubuntu, AWS CLI install)
  egress {
    description = "HTTP for apt and package downloads"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS access
  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RabbitMQ Management UI (Amazon MQ in spoke-vpc) for SSM port-forward tunneling
  egress {
    description = "RabbitMQ Management UI via SSM tunnel"
    from_port   = 15671
    to_port     = 15671
    protocol    = "tcp"
    cidr_blocks = [var.spoke_vpc_cidr]
  }

  tags = {
    Name = "payflow-bastion-sg"
  }
}

# IAM Role for Bastion
resource "aws_iam_role" "bastion" {
  name = "payflow-bastion-role"

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

  tags = {
    Name = "payflow-bastion-role"
  }
}

# IAM Policy for EKS access
resource "aws_iam_role_policy" "bastion_eks" {
  # checkov:skip=CKV_AWS_355:EKS describe actions require * resource; no resource-level permissions available for eks:DescribeCluster/ListClusters
  name = "payflow-bastion-eks-policy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      }
    ]
  })
}

# EC2/SSM read-only and scoped StartSession for operating from the bastion
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "bastion_operate" {
  # checkov:skip=CKV_AWS_355:EC2/SSM describe actions require * resource; no resource-level permissions available for DescribeInstances/DescribeSessions
  # checkov:skip=CKV_AWS_290:TerminateInstances is scoped to instances tagged payflow-* via Condition; Checkov cannot evaluate tag conditions
  name = "payflow-bastion-operate-policy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeSecurityGroups", "ec2:DescribeVpcs", "ec2:DescribeSubnets"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:DescribeSessions", "ssm:DescribeInstanceInformation"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:StartSession"]
        Resource = [
          "arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell",
          "arn:aws:ec2:*:*:instance/*"
        ]
        Condition = {
          StringLike = {
            "ec2:ResourceTag/Name" = "payflow-*"
          }
        }
      }
    ]
  })
}

# Secrets Manager — post-deploy placeholder secrets only (webhook secret, ArgoCD token + URL).
# These three secrets are created by spoke-vpc-eks Terraform with placeholder values and must
# be updated from the bastion after ArgoCD is deployed and the NLB hostname is known.
resource "aws_iam_role_policy" "bastion_secrets" {
  name = "payflow-bastion-secrets-policy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:UpdateSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:payflow/${var.environment}/github-webhook-secret*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:payflow/${var.environment}/argocd-token*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:payflow/${var.environment}/argocd-internal-url*"
        ]
      },
      {
        # GenerateDataKey encrypts the new secret value; Decrypt reads the current value.
        # Key uses default account root policy so IAM grants here are sufficient.
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# SSM Session Manager: connect without SSH keys (aws ssm start-session --target <instance-id>)
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "bastion" {
  name = "payflow-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Get latest Ubuntu 24.04 LTS AMI (Canonical owner ID: 099720109477)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Bastion Host
resource "aws_instance" "bastion" {
  # checkov:skip=CKV_AWS_135:EBS optimisation is always enabled on t3 instances by default; explicit flag not accepted by instance type
  # checkov:skip=CKV_AWS_126:Detailed EC2 monitoring not justified for a single-purpose bastion host; CloudTrail covers API audit
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.hub_public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # IMDSv2 required (security best practice)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = var.bastion_root_volume_size_gb
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/bastion-init.log) 2>&1

    export DEBIAN_FRONTEND=noninteractive
    # Run all downloads/installs from /tmp so CWD is always writable (cloud-init CWD can be read-only)
    cd /tmp

    # Update and install base packages
    apt-get update -y
    apt-get install -y \
      curl \
      unzip \
      jq \
      git \
      bash-completion \
      ca-certificates \
      gnupg \
      lsb-release

    # --- Install kubectl (pinned to stable) ---
    KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    curl -sLO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    chmod +x kubectl
    mv kubectl /usr/local/bin/
    rm -f kubectl.sha256

    # --- Install AWS CLI v2 ---
    curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    # --- Install Helm (from /tmp so script output is writable) ---
    curl -sSfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # --- Install SSM agent (usually pre-installed on Ubuntu, ensure it's running) ---
    systemctl enable amazon-ssm-agent 2>/dev/null || snap start amazon-ssm-agent 2>/dev/null || true

    # --- Create kube config directory for ubuntu user ---
    mkdir -p /home/ubuntu/.kube
    chown ubuntu:ubuntu /home/ubuntu/.kube

    # --- kubectl bash completion ---
    kubectl completion bash > /etc/bash_completion.d/kubectl
    echo 'alias k=kubectl' >> /home/ubuntu/.bashrc
    echo 'complete -o default -F __start_kubectl k' >> /home/ubuntu/.bashrc

    echo "Bastion init complete. Connect via: aws ssm start-session --target $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
  EOF

  tags = {
    Name        = "payflow-bastion"
    Environment = var.environment
    OS          = "ubuntu-24.04"
  }
}

# Elastic IP for Bastion (optional, for static IP)
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = {
    Name = "payflow-bastion-eip"
  }
}
