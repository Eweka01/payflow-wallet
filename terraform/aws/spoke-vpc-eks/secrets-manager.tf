# AWS Secrets Manager - Store sensitive credentials
# Prevents passwords from being stored in Terraform state file
#
# recovery_window_in_days = 0: secrets are deleted immediately on destroy so the
# same names can be reused on a later apply. Use 7+ if you need recovery after destroy.

# KMS Key for Secrets Manager encryption
resource "aws_kms_key" "secrets" {
  # checkov:skip=CKV2_AWS_64:KMS key uses default AWS account root policy; explicit key policy planned for production
  description             = "KMS key for Secrets Manager encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true  # Required for PCI-DSS

  tags = {
    Name = "payflow-secrets-kms-key"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/payflow-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# RDS Database Credentials Secret
resource "aws_secretsmanager_secret" "rds" {
  # checkov:skip=CKV2_AWS_57:Automatic rotation requires a Lambda rotation function; planned for production deployment
  name                    = "payflow/${local.env}/rds"
  description             = "RDS PostgreSQL credentials"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days  = 0  # Immediate delete on destroy so re-apply can reuse name

  tags = {
    Name        = "payflow-rds-secret"
    Environment = local.env
    Service     = "rds"
  }
}

# RDS Secret Version (initial value)
# Note: In production, rotate this secret and update via AWS Console or CLI
resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password  # Will be rotated after initial creation
    host     = ""  # Will be populated after RDS is created
    port     = 5432
    dbname   = var.db_name
    engine   = "postgres"
  })

  lifecycle {
    ignore_changes = [secret_string]  # Allow manual rotation without Terraform changes
  }
}

# RabbitMQ (Amazon MQ) Credentials Secret
resource "aws_secretsmanager_secret" "rabbitmq" {
  # checkov:skip=CKV2_AWS_57:Automatic rotation requires a Lambda rotation function; planned for production deployment
  name                    = "payflow/${local.env}/rabbitmq"
  description             = "Amazon MQ RabbitMQ credentials"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0  # Immediate delete on destroy so re-apply can reuse name

  tags = {
    Name        = "payflow-rabbitmq-secret"
    Environment = local.env
    Service     = "rabbitmq"
  }
}

# RabbitMQ Secret Version
resource "aws_secretsmanager_secret_version" "rabbitmq" {
  secret_id = aws_secretsmanager_secret.rabbitmq.id
  secret_string = jsonencode({
    username = var.mq_username
    password = var.mq_password
    endpoint = ""  # Will be populated after Amazon MQ is created
    port     = 5671
    protocol = "amqps"
    url      = ""  # Will be populated after Amazon MQ is created: amqps://${username}:${password}@${endpoint}:${port}
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Redis (ElastiCache) Credentials Secret
resource "aws_secretsmanager_secret" "redis" {
  # checkov:skip=CKV2_AWS_57:Automatic rotation requires a Lambda rotation function; planned for production deployment
  name                    = "payflow/${local.env}/redis"
  description             = "ElastiCache Redis connection details"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0  # Immediate delete on destroy so re-apply can reuse name

  tags = {
    Name        = "payflow-redis-secret"
    Environment = local.env
    Service     = "redis"
  }
}

# Redis Secret Version
resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string = jsonencode({
    endpoint = ""  # Will be populated after ElastiCache is created
    port     = 6379
    url      = ""  # Full connection URL
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Application Secrets (JWT, API keys, etc.)
resource "aws_secretsmanager_secret" "app_secrets" {
  # checkov:skip=CKV2_AWS_57:Automatic rotation requires a Lambda rotation function; planned for production deployment
  name                    = "payflow/${local.env}/app/secrets"
  description             = "Application secrets (JWT, API keys)"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0  # Immediate delete on destroy so re-apply can reuse name

  tags = {
    Name        = "payflow-app-secrets"
    Environment = local.env
    Service     = "application"
  }
}

# Application Secrets Version
resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    jwt_secret = var.jwt_secret
    # Add other application secrets here
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# IRSA Role for External Secrets Operator (uses local.oidc_url from irsa-roles.tf)
resource "aws_iam_role" "external_secrets_irsa" {
  name = "${var.eks_cluster_name}-external-secrets-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"
            "${local.oidc_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  depends_on = [aws_iam_openid_connect_provider.eks]

  tags = {
    Name = "${var.eks_cluster_name}-external-secrets-irsa"
  }
}

# IAM Policy for External Secrets Operator
resource "aws_iam_role_policy" "external_secrets" {
  name = "external-secrets-policy"
  role = aws_iam_role.external_secrets_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          aws_secretsmanager_secret.rds.arn,
          aws_secretsmanager_secret.rabbitmq.arn,
          aws_secretsmanager_secret.redis.arn,
          aws_secretsmanager_secret.app_secrets.arn,
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:payflow/${local.env}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.secrets.arn
        ]
      }
    ]
  })
}

# Wait for IRSA role to propagate
resource "time_sleep" "wait_for_external_secrets_irsa" {
  depends_on = [
    aws_iam_role.external_secrets_irsa,
    aws_iam_role_policy.external_secrets,
  ]
  create_duration = "20s"
}

