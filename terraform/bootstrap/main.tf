# =============================================================
# BOOTSTRAP — Run this ONCE before any other module
# Creates the S3 bucket and DynamoDB table that store
# Terraform state for all 4 modules (hub-vpc, spoke-vpc-eks,
# managed-services, bastion)
# =============================================================

terraform {
  required_version = ">= 1.5.0"

  # Bootstrap uses LOCAL state — it cannot use S3 because
  # it IS the thing that creates the S3 bucket
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Pull current account ID dynamically — no hardcoding
data "aws_caller_identity" "current" {}

# =============================================================
# S3 BUCKET — stores all .tfstate files
# =============================================================

resource "aws_s3_bucket" "tfstate" {
  # checkov:skip=CKV_AWS_18:Access logging requires a dedicated logging bucket; adds cost/complexity not warranted for a state-only bucket
  # checkov:skip=CKV_AWS_144:Cross-region replication not required; versioning provides recovery capability
  # checkov:skip=CKV_AWS_145:Uses SSE-S3 (AES256); KMS CMK adds cost and management overhead for a non-data-serving bucket
  # Name includes account ID to guarantee global uniqueness
  bucket = "payflow-tfstate-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental destroy — losing this bucket means
  # losing all Terraform state for every module
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "payflow-terraform-state"
    Project = "payflow"
  }
}

# Versioning — every terraform apply creates a new state version
# If a bad apply corrupts state, roll back to a previous version
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest — state files contain sensitive data
# (resource IDs, ARNs, sometimes secrets)
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — state files must never be public
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================
# DYNAMODB TABLE — state locking
# =============================================================

resource "aws_dynamodb_table" "tfstate_lock" {
  # checkov:skip=CKV_AWS_119:DynamoDB default encryption (AWS managed) is sufficient; KMS CMK adds cost not justified for a state lock table
  name         = "payflow-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST" # No provisioned capacity needed
  hash_key     = "LockID"          # Terraform requires exactly this key name

  attribute {
    name = "LockID"
    type = "S" # String type
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "payflow-terraform-state-lock"
    Project = "payflow"
  }
}

# =============================================================
# OUTPUTS — copy these values to confirm it worked
# =============================================================

output "bucket_name" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "S3 bucket storing all Terraform state"
}

output "dynamodb_table" {
  value       = aws_dynamodb_table.tfstate_lock.name
  description = "DynamoDB table for state locking"
}
