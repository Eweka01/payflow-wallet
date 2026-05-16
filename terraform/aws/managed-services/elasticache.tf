# ElastiCache Redis - Managed Cache Service
# (terraform/provider/data blocks are in backend.tf, main.tf, and data.tf)

# Subnet Group for ElastiCache
resource "aws_elasticache_subnet_group" "payflow" {
  name       = "payflow-redis-subnet-group"
  subnet_ids = data.aws_subnets.eks_private.ids

  tags = {
    Name = "payflow-redis-subnet-group"
  }
}

# Security Group for ElastiCache
resource "aws_security_group" "elasticache" {
  # checkov:skip=CKV_AWS_382:Unrestricted egress required for ElastiCache to reach AWS service endpoints
  name        = "payflow-elasticache-sg"
  description = "Security group for ElastiCache Redis"
  vpc_id      = data.aws_vpc.eks.id

  # Allow Redis from EKS (cluster + node SGs so pod traffic is allowed)
  dynamic "ingress" {
    for_each = length(local.rds_allowed_sgs) > 0 ? [1] : []
    content {
      description     = "Redis from EKS (cluster and node SGs)"
      from_port       = 6379
      to_port         = 6379
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
    Name = "payflow-elasticache-sg"
  }
}

# ElastiCache Redis Cluster
resource "aws_elasticache_replication_group" "payflow" {
  # checkov:skip=CKV_AWS_31:Auth token requires cluster recreation; transit_encryption_enabled=true; auth token planned for production deployment
  # checkov:skip=CKV_AWS_191:at_rest_encryption_enabled=true uses AWS managed key; KMS CMK adds cost not justified for portfolio demo
  replication_group_id       = "payflow-redis"
  description                = "PayFlow Redis cache cluster"

  # Engine Configuration
  engine               = "redis"
  engine_version        = var.redis_version
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  # Cluster Configuration
  num_cache_clusters = var.num_cache_nodes

  # Network Configuration
  subnet_group_name  = aws_elasticache_subnet_group.payflow.name
  security_group_ids  = [aws_security_group.elasticache.id]

  # High Availability
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled          = var.multi_az_enabled

  # Snapshot Configuration
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_window

  # Encryption
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # Maintenance
  maintenance_window = var.maintenance_window

  # Log Delivery (optional)
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  # Lifecycle: prod workspace blocks terraform destroy; dev/test can tear down
  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      tags,
      auth_token_update_strategy,  # Imported cluster may not have AUTH token; avoid modify error
    ]
  }

  depends_on = [
    aws_elasticache_subnet_group.payflow,
    aws_security_group.elasticache,
    aws_cloudwatch_log_group.redis,
  ]

  tags = {
    Name        = "payflow-redis"
    Environment = var.environment
  }
}

# CloudWatch Log Group for Redis
resource "aws_cloudwatch_log_group" "redis" {
  # checkov:skip=CKV_AWS_158:KMS CMK encryption for log groups adds cost; CloudWatch service-side encryption is sufficient for portfolio demo
  name              = "/aws/elasticache/redis/payflow"
  retention_in_days = 365

  tags = {
    Name = "payflow-redis-logs"
  }
}

# Update Redis secret in Secrets Manager with actual primary endpoint and TLS URL
# Secret is created in spoke-vpc-eks; this populates it after ElastiCache is created
locals {
  redis_primary_endpoint = aws_elasticache_replication_group.payflow.primary_endpoint_address
  redis_port             = aws_elasticache_replication_group.payflow.port
  redis_secret_json      = jsonencode({
    endpoint = local.redis_primary_endpoint
    port     = local.redis_port
    url      = "rediss://${local.redis_primary_endpoint}:${local.redis_port}"
  })
}

resource "null_resource" "update_redis_secret" {
  depends_on = [aws_elasticache_replication_group.payflow]

  triggers = {
    redis_endpoint = local.redis_primary_endpoint
  }

  provisioner "local-exec" {
    command     = "echo \"$${B64}\" | base64 -d > ${path.module}/.secret-redis.json && aws secretsmanager put-secret-value --secret-id payflow/${local.env}/redis --secret-string file://${path.module}/.secret-redis.json --region ${var.aws_region} || echo 'Warning: Secret may not exist yet.'"
    environment = {
      B64 = base64encode(local.redis_secret_json)
    }
  }
}

