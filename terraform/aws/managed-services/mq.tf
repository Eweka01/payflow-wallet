# Amazon MQ (RabbitMQ) - Managed Message Queue Service
# (terraform/provider/data blocks are in backend.tf, main.tf, and data.tf)

# Security Group for Amazon MQ
resource "aws_security_group" "mq" {
  # checkov:skip=CKV_AWS_382:Unrestricted egress required for MQ broker to reach AWS service endpoints
  name        = "payflow-mq-sg"
  description = "Security group for Amazon MQ (RabbitMQ)"
  vpc_id      = data.aws_vpc.eks.id

  # Allow AMQP from EKS (cluster + node SGs so pod traffic is allowed)
  dynamic "ingress" {
    for_each = length(local.rds_allowed_sgs) > 0 ? [1] : []
    content {
      description     = "AMQP from EKS (cluster and node SGs)"
      from_port       = 5671
      to_port         = 5671
      protocol        = "tcp"
      security_groups = local.rds_allowed_sgs
    }
  }

  # Allow Management UI from EKS (optional, for debugging)
  dynamic "ingress" {
    for_each = length(local.rds_allowed_sgs) > 0 ? [1] : []
    content {
      description     = "RabbitMQ Management UI from EKS"
      from_port       = 15671
      to_port         = 15671
      protocol        = "tcp"
      security_groups = local.rds_allowed_sgs
    }
  }

  # Allow Management UI from bastion (hub-vpc private IP) for SSM port-forward tunneling
  dynamic "ingress" {
    for_each = var.bastion_private_cidr != null ? [1] : []
    content {
      description = "RabbitMQ Management UI from bastion (SSM tunnel)"
      from_port   = 15671
      to_port     = 15671
      protocol    = "tcp"
      cidr_blocks = [var.bastion_private_cidr]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "payflow-mq-sg"
  }
}

# Amazon MQ Broker (RabbitMQ)
resource "aws_mq_broker" "payflow" {
  broker_name                 = "payflow-rabbitmq"
  engine_type                 = "RabbitMQ"
  engine_version              = var.rabbitmq_version
  host_instance_type           = var.mq_instance_type
  auto_minor_version_upgrade   = true # Required for RabbitMQ 3.13+

  # Authentication
  user {
    username = var.rabbitmq_username
    password = var.rabbitmq_password # In production, use AWS Secrets Manager
  }

  # Network Configuration (SINGLE_INSTANCE requires exactly 1 subnet; ACTIVE_STANDBY_MULTI_AZ uses 2)
  subnet_ids         = var.mq_deployment_mode == "SINGLE_INSTANCE" ? slice(data.aws_subnets.eks_private.ids, 0, 1) : slice(data.aws_subnets.eks_private.ids, 0, min(2, length(data.aws_subnets.eks_private.ids)))
  security_groups    = [aws_security_group.mq.id]
  publicly_accessible = false

  # High Availability (optional, costs more)
  deployment_mode    = var.mq_deployment_mode
  maintenance_window_start_time {
    day_of_week = "MONDAY"
    time_of_day = "03:00"
    time_zone   = "UTC"
  }

  # Logging
  logs {
    general = true
    audit   = false
  }

  # Encryption
  encryption_options {
    kms_key_id        = aws_kms_key.mq.arn
    use_aws_owned_key = false
  }

  tags = {
    Name        = "payflow-rabbitmq"
    Environment = var.environment
  }

  # Imported broker may use a different KMS key; ignore to avoid replace/destroy
  lifecycle {
    ignore_changes = [encryption_options]
  }
}

# KMS Key for Amazon MQ Encryption
resource "aws_kms_key" "mq" {
  # checkov:skip=CKV2_AWS_64:KMS key uses default AWS account root policy; explicit key policy planned for production
  description             = "KMS key for Amazon MQ encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "payflow-mq-kms-key"
  }
}

# Hostname and secret JSON built in Terraform so the shell needs no substitution or escaping
locals {
  mq_endpoint_full = aws_mq_broker.payflow.instances[0].endpoints[0]
  mq_host          = split(":", replace(replace(local.mq_endpoint_full, "amqps://", ""), "amqp://", ""))[0]
  mq_secret_json   = jsonencode({
    username = var.rabbitmq_username
    password = var.rabbitmq_password
    endpoint = local.mq_host
    port     = 5671
    protocol = "amqps"
    url      = "amqps://${var.rabbitmq_username}:${var.rabbitmq_password}@${local.mq_host}:5671"
  })
}

# Update RabbitMQ secret in Secrets Manager with actual endpoint and URL
# Note: Secret must exist in spoke-vpc-eks module first
resource "null_resource" "update_rabbitmq_secret" {
  depends_on = [aws_mq_broker.payflow]

  triggers = {
    mq_endpoint = aws_mq_broker.payflow.instances[0].endpoints[0]
  }

  provisioner "local-exec" {
    command     = "echo \"$${B64}\" | base64 -d > ${path.module}/.secret-mq.json && aws secretsmanager put-secret-value --secret-id payflow/${local.env}/rabbitmq --secret-string file://${path.module}/.secret-mq.json --region ${var.aws_region} || echo 'Warning: Secret may not exist yet.'"
    environment = { B64 = base64encode(local.mq_secret_json) }
  }
}

