# AWS WAF v2 - Web Application Firewall
# Required for fintech/PCI-DSS compliance
# Protects ALB from common attacks

# WAF Web ACL
resource "aws_wafv2_web_acl" "payflow" {
  name        = "payflow-${var.environment}-waf"
  description = "WAF for PayFlow API Gateway"
  scope       = "REGIONAL"  # For ALB (not CloudFront)

  default_action {
    allow {}
  }

  # AWS Managed Rule - Common Rule Set
  # Blocks common attacks (SQL injection, XSS, etc.)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rule - SQL Injection Protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rule - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rule - Linux Operating System Protection
  rule {
    name     = "AWSManagedRulesLinuxRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "LinuxRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rate Limiting Rule - Protect payment endpoints
  rule {
    name     = "RateLimitRule"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000  # 2000 requests per 5 minutes per IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  # Geo-blocking rule (optional - uncomment if needed)
  # rule {
  #   name     = "GeoBlockRule"
  #   priority = 20
  #
  #   action {
  #     block {}
  #   }
  #
  #   statement {
  #     geo_match_statement {
  #       country_codes = ["CN", "RU", "KP"]  # Block specific countries
  #     }
  #   }
  #
  #   visibility_config {
  #     cloudwatch_metrics_enabled = true
  #     metric_name                = "GeoBlockMetric"
  #     sampled_requests_enabled   = true
  #   }
  # }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "PayflowWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "payflow-waf"
    Environment = var.environment
  }
}

# CloudWatch Log Group for WAF (name must start with aws-waf-logs- per AWS WAFv2)
resource "aws_cloudwatch_log_group" "waf" {
  # checkov:skip=CKV_AWS_158:KMS CMK for CW log groups adds cost; CloudWatch service-side encryption is sufficient for portfolio demo
  name              = "aws-waf-logs-${var.eks_cluster_name}"
  retention_in_days = 365  # 1 year retention

  tags = {
    Name = "payflow-waf-logs"
  }
}

# WAF Logging Configuration (log group ARN must end with :* for WAFv2)
resource "aws_wafv2_web_acl_logging_configuration" "payflow" {
  resource_arn            = aws_wafv2_web_acl.payflow.arn
  log_destination_configs = ["${aws_cloudwatch_log_group.waf.arn}:*"]

  redacted_fields {
    single_header {
      name = "authorization"  # Redact authorization headers in logs
    }
  }
}

# Disassociate WAF from ALB before destroying Web ACL (ALB is created by K8s Ingress, not Terraform)
resource "null_resource" "waf_disassociate" {
  depends_on = [aws_wafv2_web_acl_logging_configuration.payflow]

  triggers = {
    web_acl_arn = aws_wafv2_web_acl.payflow.arn
    region      = data.aws_region.current.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      ARN="${self.triggers.web_acl_arn}"
      REGION="${self.triggers.region}"
      for resource in $(aws wafv2 list-resources-for-web-acl --scope REGIONAL --web-acl-arn "$ARN" --region "$REGION" --query 'ResourceArns[]' --output text 2>/dev/null | tr '\t' '\n'); do
        [ -n "$resource" ] && aws wafv2 disassociate-web-acl --resource-arn "$resource" --region "$REGION" 2>/dev/null || true
      done
    EOT
  }
}

# Note: WAF association with ALB is done via ALB Ingress Controller annotations
# See: k8s/overlays/eks/ingress-patch.yaml
# Annotation: alb.ingress.kubernetes.io/wafv2-acl-arn

