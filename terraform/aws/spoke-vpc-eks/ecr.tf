# ECR Repositories for Container Images
# Each service gets its own repository (KMS-CMK for PCI-DSS)

resource "aws_kms_key" "ecr" {
  description             = "KMS key for ECR repository encryption"
  deletion_window_in_days  = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow ECR service to use the key"
        Effect = "Allow"
        Principal = { Service = "ecr.amazonaws.com" }
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        # EKS nodes must be able to decrypt ECR image manifests at pull time.
        # AmazonEC2ContainerRegistryReadOnly does NOT grant kms:Decrypt - this does.
        Sid    = "Allow EKS nodes to pull KMS-encrypted ECR images"
        Effect = "Allow"
        Principal = { AWS = aws_iam_role.eks_node.arn }
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/payflow-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

# ECR Repository for API Gateway
resource "aws_ecr_repository" "api_gateway" {
  name                 = "${var.eks_cluster_name}/api-gateway"
  image_tag_mutability = "IMMUTABLE"  # Prevent image tampering (fintech requirement)
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true  # Scan images for vulnerabilities on push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-api-gateway"
    Environment = var.environment
    Service     = "api-gateway"
  }
}

# ECR Repository for Auth Service
resource "aws_ecr_repository" "auth_service" {
  name                 = "${var.eks_cluster_name}/auth-service"
  image_tag_mutability = "IMMUTABLE"  # Prevent image tampering (fintech requirement)
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-auth-service"
    Environment = var.environment
    Service     = "auth-service"
  }
}

# ECR Repository for Wallet Service
resource "aws_ecr_repository" "wallet_service" {
  name                 = "${var.eks_cluster_name}/wallet-service"
  image_tag_mutability = "IMMUTABLE"  # Prevent image tampering (fintech requirement)
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-wallet-service"
    Environment = var.environment
    Service     = "wallet-service"
  }
}

# ECR Repository for Transaction Service
resource "aws_ecr_repository" "transaction_service" {
  name                 = "${var.eks_cluster_name}/transaction-service"
  image_tag_mutability = "IMMUTABLE"  # Prevent image tampering (fintech requirement)
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-transaction-service"
    Environment = var.environment
    Service     = "transaction-service"
  }
}

# ECR Repository for Notification Service
resource "aws_ecr_repository" "notification_service" {
  name                 = "${var.eks_cluster_name}/notification-service"
  image_tag_mutability = "IMMUTABLE"  # Prevent image tampering (fintech requirement)
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-notification-service"
    Environment = var.environment
    Service     = "notification-service"
  }
}

# ECR Repository for DB Migrations (Flyway image with versioned SQL files baked in)
resource "aws_ecr_repository" "db_migrations" {
  name                 = "${var.eks_cluster_name}/db-migrations"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-db-migrations"
    Environment = var.environment
    Service     = "db-migrations"
  }
}

# ECR Repository for Frontend
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.eks_cluster_name}/frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true         # Allow destroy when repo has images (teardown)

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.eks_cluster_name}-frontend"
    Environment = var.environment
    Service     = "frontend"
  }
}

# ECR Lifecycle Policy - Keep last 10 images, delete older
resource "aws_ecr_lifecycle_policy" "default" {
  for_each = {
    api_gateway          = aws_ecr_repository.api_gateway.name
    auth_service         = aws_ecr_repository.auth_service.name
    wallet_service       = aws_ecr_repository.wallet_service.name
    transaction_service  = aws_ecr_repository.transaction_service.name
    notification_service = aws_ecr_repository.notification_service.name
    frontend             = aws_ecr_repository.frontend.name
    db_migrations        = aws_ecr_repository.db_migrations.name
  }

  repository = each.value

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "any"
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

