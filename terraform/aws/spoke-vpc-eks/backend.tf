# Terraform Backend Configuration
# This file configures where Terraform stores its state
# 
# IMPORTANT: Run bootstrap.sh FIRST to create S3 bucket and DynamoDB table
# Then update the bucket name and table name below with your values

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    # Update these values after running bootstrap.sh
    # State files are automatically separated by workspace:
    # - env:/dev/aws/eks/terraform.tfstate
    # - env:/prod/aws/eks/terraform.tfstate
    bucket         = "payflow-tfstate-470439679607"  # Replace ACCOUNT_ID with your AWS account ID
    key            = "aws/eks/terraform.tfstate"  # Workspace prefix added automatically
    region         = "us-east-1"
    dynamodb_table = "payflow-tfstate-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

