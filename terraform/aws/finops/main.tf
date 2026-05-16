terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  # Common FinOps tags applied to all AWS FinOps resources
  common_tags = {
    project       = "payflow"
    environment   = var.environment
    team          = var.team
    owner         = var.owner
    "cost-center" = var.cost_center
    "managed-by"  = "terraform"
    module        = "aws-finops"
  }
}

# ---------------------------------------------------------------------------
# Cost allocation tags (mark as cost-allocation in billing console)
# Only enable after these tag keys exist on resources and appear in Cost Explorer.
# ---------------------------------------------------------------------------

resource "aws_ce_cost_allocation_tag" "finops" {
  for_each = var.enable_cost_allocation_tags ? toset([
    "environment",
    "project",
    "team",
    "cost-center",
    "owner",
    "managed-by",
    "module",
  ]) : toset([])

  tag_key = each.key
  status  = "Active"
}

# ---------------------------------------------------------------------------
# AWS Budgets per environment (dev and prod)
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "dev" {
  name              = "payflow-dev-monthly-budget"
  budget_type       = "COST"
  time_unit         = "MONTHLY"
  limit_amount      = tostring(var.monthly_budget_dev)
  limit_unit        = "USD"
  time_period_start = "2024-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "environment$dev"
    ]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = var.budget_alert_threshold_percent
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"

    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = merge(local.common_tags, {
    Name   = "payflow-dev-monthly-budget"
    module = "aws-finops"
  })
}

resource "aws_budgets_budget" "prod" {
  name              = "payflow-prod-monthly-budget"
  budget_type       = "COST"
  time_unit         = "MONTHLY"
  limit_amount      = tostring(var.monthly_budget_prod)
  limit_unit        = "USD"
  time_period_start = "2024-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "environment$prod"
    ]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = var.budget_alert_threshold_percent
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"

    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = merge(local.common_tags, {
    Name   = "payflow-prod-monthly-budget"
    module = "aws-finops"
  })
}

# ---------------------------------------------------------------------------
# Cost Anomaly Detection (optional; account limit on dimensional monitors)
# ---------------------------------------------------------------------------

resource "aws_ce_anomaly_monitor" "account" {
  count             = var.enable_anomaly_detection ? 1 : 0
  name              = "payflow-account-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = merge(local.common_tags, {
    Name   = "payflow-account-anomaly-monitor"
    module = "aws-finops"
  })
}

resource "aws_ce_anomaly_subscription" "account" {
  count       = var.enable_anomaly_detection ? 1 : 0
  name        = "payflow-account-anomaly-subscription"
  frequency   = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.account[0].arn]

  threshold_expression {
    or {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        values        = ["50"]
        match_options = ["GREATER_THAN_OR_EQUAL"]
      }
    }
  }

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_email
  }

  tags = merge(local.common_tags, {
    Name   = "payflow-account-anomaly-subscription"
    module = "aws-finops"
  })
}

# ---------------------------------------------------------------------------
# SNS topic for billing alarm (same email as budget/anomaly alerts)
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "billing_alarm" {
  # checkov:skip=CKV_AWS_26:KMS CMK for SNS adds cost; billing alarm notifications are non-sensitive operational data
  name = "payflow-billing-alarm"

  tags = merge(local.common_tags, {
    Name   = "payflow-billing-alarm"
    module = "aws-finops"
  })
}

resource "aws_sns_topic_subscription" "billing_alarm_email" {
  topic_arn = aws_sns_topic.billing_alarm.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

# ---------------------------------------------------------------------------
# CloudWatch billing alarm — pages when account EstimatedCharges exceeds threshold
# (Billing metrics exist only in us-east-1; provider region should be us-east-1.)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "billing_estimated_charges" {
  alarm_name          = "payflow-billing-estimated-charges"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400
  statistic           = "Maximum"
  threshold           = var.billing_alarm_threshold_usd

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing_alarm.arn]
  ok_actions    = [aws_sns_topic.billing_alarm.arn]

  alarm_description  = "Account-level estimated charges exceeded threshold (align with budget limit)."
  treat_missing_data = "notBreaching"
}

# ---------------------------------------------------------------------------
# CloudWatch dashboard for high-level cost visibility
# (Note: detailed cost-by-tag views still live in Cost Explorer/Cost & Usage Reports)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "cost_overview" {
  dashboard_name = "payflow-cost-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    = 0
        y    = 0
        width  = 24
        height = 6
        properties = {
          title = "EstimatedCharges (Account Level)"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
          ]
          region  = var.aws_region
          period  = 21600
          stat    = "Maximum"
          view    = "timeSeries"
          stacked = false
        }
      }
    ]
  })
}

