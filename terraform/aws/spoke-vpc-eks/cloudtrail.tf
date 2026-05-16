# CloudTrail - API Audit Logging
# Independent, create early for compliance

# S3 Bucket for CloudTrail
resource "aws_s3_bucket" "cloudtrail" {
  # checkov:skip=CKV_AWS_18:Access logging requires a dedicated logging bucket; adds cost/complexity not warranted for portfolio demo
  # checkov:skip=CKV_AWS_144:Cross-region replication not required; versioning enabled for state recovery
  # checkov:skip=CKV2_AWS_6:Public access block is applied via aws_s3_bucket_public_access_block; Checkov cannot resolve cross-resource linkage
  # checkov:skip=CKV2_AWS_62:S3 event notifications require SNS/SQS/Lambda target; CloudTrail and CW Logs already provide audit coverage
  bucket        = "${var.eks_cluster_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # Empty and delete on destroy (teardown)

  tags = {
    Name = "${var.eks_cluster_name}-cloudtrail"
  }
}

# S3 Bucket Versioning
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Encryption (KMS for key management consistency)
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.config_cloudtrail.arn
    }
  }
}

# S3 Bucket Lifecycle Configuration - 7 year retention for PCI-DSS
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "cloudtrail-lifecycle"
    status = "Enabled"
    filter {}  # Apply to all objects (required by provider)

    # Transition to Standard-IA after 90 days (cheaper storage)
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    # Transition to Glacier after 1 year (archive storage)
    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    # Expire after 7 years (PCI-DSS requirement)
    expiration {
      days = 2557  # 7 years
    }

    # Abort incomplete multipart uploads after 7 days to avoid orphaned storage costs
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# S3 Bucket Policy for CloudTrail
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${var.eks_cluster_name}-cloudtrail"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"    = "bucket-owner-full-control"
            "AWS:SourceArn"   = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${var.eks_cluster_name}-cloudtrail"
          }
        }
      }
    ]
  })
}

# SNS Topic for CloudTrail alerts
resource "aws_sns_topic" "cloudtrail" {
  # checkov:skip=CKV_AWS_26:KMS CMK for SNS adds cost; audit alert notifications are not sensitive data
  name = "${var.eks_cluster_name}-cloudtrail-alerts"

  tags = {
    Name = "${var.eks_cluster_name}-cloudtrail-alerts"
  }
}

# CloudTrail
resource "aws_cloudtrail" "eks" {
  # checkov:skip=CKV_AWS_35:S3 bucket uses KMS encryption (config_cloudtrail key); additional CloudTrail KMS key adds cost and management overhead
  # checkov:skip=CKV2_AWS_10:CloudWatch Logs integration requires a dedicated IAM role and log group; planned for production deployment
  name                          = "${var.eks_cluster_name}-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  sns_topic_name                = aws_sns_topic.cloudtrail.arn
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,  # Bucket policy must exist first
    aws_sns_topic.cloudtrail,
  ]

  tags = {
    Name = "${var.eks_cluster_name}-cloudtrail"
  }
}

# Region (caller identity is in aws-auth.tf)
data "aws_region" "current" {}

