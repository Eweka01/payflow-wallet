# AWS Config - Compliance Monitoring
# Tracks configuration changes and compliance status

# KMS key for Config and CloudTrail S3 buckets (aws:kms SSE)
resource "aws_kms_key" "config_cloudtrail" {
  description             = "KMS key for Config and CloudTrail S3 encryption"
  deletion_window_in_days  = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Root"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Config"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid    = "CloudTrail"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "config_cloudtrail" {
  name          = "alias/payflow-config-cloudtrail"
  target_key_id = aws_kms_key.config_cloudtrail.key_id
}

# S3 Bucket for Config
resource "aws_s3_bucket" "config" {
  # checkov:skip=CKV_AWS_18:Access logging requires a dedicated logging bucket; adds cost/complexity not warranted for portfolio demo
  # checkov:skip=CKV_AWS_144:Cross-region replication not required; versioning provides recovery capability
  bucket        = "${var.eks_cluster_name}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # Empty and delete on destroy (teardown)

  tags = {
    Name = "${var.eks_cluster_name}-config"
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.config_cloudtrail.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Config Delivery Channel
resource "aws_config_delivery_channel" "payflow" {
  name           = "payflow-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.payflow]
}

# Config Configuration Recorder
resource "aws_config_configuration_recorder" "payflow" {
  name     = "payflow-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# IAM Role for Config
resource "aws_iam_role" "config" {
  name = "${var.eks_cluster_name}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.eks_cluster_name}-config-role"
  }
}

# IAM Policy for Config (AWS managed policy for Config recorder)
resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-policy"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.config.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketAcl"
        ]
        Resource = aws_s3_bucket.config.arn
      }
    ]
  })
}

# Start Config Recorder
resource "aws_config_configuration_recorder_status" "payflow" {
  name       = aws_config_configuration_recorder.payflow.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.payflow]
}

