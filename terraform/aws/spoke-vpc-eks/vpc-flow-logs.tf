# VPC Flow Logs - Network Traffic Monitoring
# Attach immediately to VPC for security and compliance

# IAM Role for VPC Flow Logs
resource "aws_iam_role" "flow_logs" {
  name = "${var.eks_cluster_name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.eks_cluster_name}-flow-logs-role"
  }
}

# IAM Policy for VPC Flow Logs (scoped to our log group to limit blast radius)
resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.eks_cluster_name}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.flow_logs.arn,
          "${aws_cloudwatch_log_group.flow_logs.arn}:*"
        ]
      }
    ]
  })
}

# CloudWatch Log Group for VPC Flow Logs (name includes workspace to avoid conflicts)
resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_158:KMS CMK for CW log groups adds cost; CloudWatch service-side encryption is sufficient for portfolio demo
  name              = "/aws/vpc-flow-logs/${var.eks_cluster_name}-${terraform.workspace}"
  retention_in_days  = 365  # 1 year minimum for fintech compliance

  tags = {
    Name = "${var.eks_cluster_name}-${terraform.workspace}-flow-logs"
  }
}

# Wait for IAM to propagate
resource "time_sleep" "wait_for_flow_logs_iam" {
  depends_on = [
    aws_iam_role.flow_logs,
    aws_iam_role_policy.flow_logs,
  ]
  create_duration = "20s"
}

# VPC Flow Logs - attach immediately to VPC
resource "aws_flow_log" "eks" {
  vpc_id          = aws_vpc.eks.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type = "cloud-watch-logs"

  depends_on = [
    aws_vpc.eks,
    time_sleep.wait_for_flow_logs_iam,
  ]

  tags = {
    Name = "${var.eks_cluster_name}-flow-logs"
  }
}

