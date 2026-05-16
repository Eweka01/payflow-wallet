# RDS PostgreSQL - Managed Database Service
# (terraform/provider/data blocks are in backend.tf, main.tf, and data.tf)

# Use default PostgreSQL version for the given major (avoids "multiple RDS engine versions" / "Cannot find version" errors)
# var.postgres_version is major-version prefix, e.g. "16" or "15"
data "aws_rds_engine_version" "postgres" {
  engine       = "postgres"
  version      = var.postgres_version
  default_only = true
}

locals {
  rds_multi_az     = var.environment == "prod" ? true : var.multi_az
  postgres_version = data.aws_rds_engine_version.postgres.version
  postgres_family  = regex("^(\\d+)", local.postgres_version)[0]
}

# DB Subnet Group
resource "aws_db_subnet_group" "payflow" {
  name       = "payflow-db-subnet-group"
  subnet_ids = data.aws_subnets.eks_private.ids

  tags = {
    Name = "payflow-db-subnet-group"
  }
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  name        = "payflow-rds-sg"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = data.aws_vpc.eks.id

  # Allow PostgreSQL from EKS nodes (cluster SG + node SG so pod traffic is allowed)
  dynamic "ingress" {
    for_each = length(local.rds_allowed_sgs) > 0 ? [1] : []
    content {
      description     = "PostgreSQL from EKS (cluster and node SGs)"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = local.rds_allowed_sgs
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
    Name = "payflow-rds-sg"
  }
}

# KMS Key for RDS Encryption
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true  # Required for PCI-DSS compliance

  tags = {
    Name = "payflow-rds-kms-key"
  }
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "payflow" {
  identifier = "payflow-postgres"

  # Engine Configuration
  engine         = "postgres"
  engine_version = local.postgres_version
  instance_class = var.db_instance_class

  # Database Configuration
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password # In production, use AWS Secrets Manager

  # Storage Configuration
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted      = true
  kms_key_id            = aws_kms_key.rds.arn

  # Network Configuration
  db_subnet_group_name   = aws_db_subnet_group.payflow.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # High Availability: always Multi-AZ for prod; optional for other envs via var.multi_az
  multi_az               = local.rds_multi_az
  availability_zone      = local.rds_multi_az ? null : var.availability_zone

  # Backup Configuration
  backup_retention_period = var.backup_retention_period
  backup_window          = var.backup_window
  maintenance_window     = var.maintenance_window
  copy_tags_to_snapshot  = true

  # Performance Insights
  performance_insights_enabled = var.performance_insights_enabled

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Deletion Protection
  deletion_protection = var.deletion_protection
  skip_final_snapshot = !var.deletion_protection
  # Required when skip_final_snapshot is false (e.g. deletion_protection was true)
  final_snapshot_identifier = var.deletion_protection ? "payflow-postgres-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  # Timeouts for slow operations
  timeouts {
    create = "40m"
    update = "80m"
    delete = "40m"
  }

  # Lifecycle: prod workspace blocks terraform destroy; non-prod can tear down
  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      password,  # Don't recreate if password changes (use AWS Secrets Manager)
      tags,
      kms_key_id,  # Imported RDS may use a different KMS key; avoid replace/destroy
      # skip_final_snapshot and final_snapshot_identifier NOT ignored so destroy works when deletion_protection=false
    ]
  }

  depends_on = [
    aws_db_subnet_group.payflow,
    aws_security_group.rds,
    aws_kms_key.rds,
  ]

  tags = {
    Name        = "payflow-postgres"
    Environment = var.environment
  }
}

# DB Parameter Group (optional, for custom PostgreSQL settings)
# Name includes environment to avoid "already exists" when state is lost or multiple envs share an account.
resource "aws_db_parameter_group" "payflow" {
  name   = "payflow-postgres-params-${var.environment}"
  family = "postgres${local.postgres_family}"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot" # static parameter; requires DB restart to take effect
  }

  tags = {
    Name = "payflow-postgres-params-${var.environment}"
  }
}

# Update RDS secret in Secrets Manager with actual endpoint
# Note: Secret must exist in spoke-vpc-eks module first
resource "null_resource" "update_rds_secret" {
  depends_on = [
    aws_db_instance.payflow
  ]

  triggers = {
    rds_endpoint = aws_db_instance.payflow.endpoint
  }

  provisioner "local-exec" {
    command     = "echo \"$${B64}\" | base64 -d > ${path.module}/.secret-rds.json && aws secretsmanager put-secret-value --secret-id payflow/${local.env}/rds --secret-string file://${path.module}/.secret-rds.json --region ${var.aws_region} || echo 'Warning: Secret may not exist yet.'"
    environment = {
      B64 = base64encode(jsonencode({
        username = var.db_username
        password = var.db_password
        host     = aws_db_instance.payflow.address
        port     = 5432
        dbname   = var.db_name
        engine   = "postgres"
      }))
    }
  }
}

