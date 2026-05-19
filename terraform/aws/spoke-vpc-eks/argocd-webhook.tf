# ============================================================
# ArgoCD Webhook — API Gateway + Lambda
# ============================================================
# Flow:
#   GitHub push → API Gateway (public HTTPS) → Lambda (private subnet)
#     → validates HMAC signature → calls ArgoCD internal NLB → sync
#
# Why Lambda instead of making ArgoCD public:
#   ArgoCD stays 100% private (internal NLB only).
#   API Gateway handles TLS (AWS-managed cert, no maintenance).
#   Lambda validates the GitHub HMAC before ArgoCD ever sees the request.

# ============================================================
# Secrets Manager — three secrets Lambda reads at runtime
# ============================================================

# 1. GitHub webhook secret — shared with GitHub when configuring the webhook.
#    GitHub signs every payload with this secret; Lambda rejects anything that
#    doesn't match. Generate with: openssl rand -hex 32
resource "aws_secretsmanager_secret" "github_webhook_secret" {
  # checkov:skip=CKV2_AWS_57:Webhook secret does not need automatic rotation; rotated manually when GitHub webhook is updated
  name                    = "payflow/${local.env}/github-webhook-secret"
  description             = "HMAC secret shared between GitHub webhook and Lambda"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0

  tags = merge(local.common_tags, { Name = "payflow-github-webhook-secret" })
}

resource "aws_secretsmanager_secret_version" "github_webhook_secret" {
  secret_id     = aws_secretsmanager_secret.github_webhook_secret.id
  secret_string = "REPLACE_WITH_WEBHOOK_SECRET"   # replaced post-deploy — see outputs

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# 2. ArgoCD API token — generated from the ArgoCD UI or CLI after first deploy.
#    Used by Lambda to authenticate the sync call.
#    How to generate: argocd account generate-token --account webhook-lambda
resource "aws_secretsmanager_secret" "argocd_token" {
  # checkov:skip=CKV2_AWS_57:ArgoCD token rotation is handled via ArgoCD UI; auto-rotation not applicable
  name                    = "payflow/${local.env}/argocd-token"
  description             = "ArgoCD API token for Lambda webhook sync"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0

  tags = merge(local.common_tags, { Name = "payflow-argocd-token" })
}

resource "aws_secretsmanager_secret_version" "argocd_token" {
  secret_id     = aws_secretsmanager_secret.argocd_token.id
  secret_string = "REPLACE_WITH_ARGOCD_TOKEN"   # replaced post-deploy — see outputs

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# 3. ArgoCD internal NLB URL — the HTTPS URL of the internal NLB created when
#    you annotate the argocd-server service as internal. Populated post-deploy.
#    How to get: kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
resource "aws_secretsmanager_secret" "argocd_internal_url" {
  # checkov:skip=CKV2_AWS_57:Internal URL is infrastructure config, not a rotating credential
  name                    = "payflow/${local.env}/argocd-internal-url"
  description             = "ArgoCD internal NLB URL — https://<internal-nlb-dns>"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0

  tags = merge(local.common_tags, { Name = "payflow-argocd-internal-url" })
}

resource "aws_secretsmanager_secret_version" "argocd_internal_url" {
  secret_id     = aws_secretsmanager_secret.argocd_internal_url.id
  secret_string = "https://REPLACE_WITH_ARGOCD_INTERNAL_NLB_DNS"   # replaced post-deploy

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ============================================================
# Lambda IAM Role
# ============================================================

resource "aws_iam_role" "argocd_webhook_lambda" {
  name = "${local.name_prefix}-argocd-webhook-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-lambda-role" })
}

resource "aws_iam_role_policy" "argocd_webhook_lambda" {
  name = "${local.name_prefix}-argocd-webhook-lambda-policy"
  role = aws_iam_role.argocd_webhook_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.github_webhook_secret.arn,
          aws_secretsmanager_secret.argocd_token.arn,
          aws_secretsmanager_secret.argocd_internal_url.arn,
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.secrets.arn]
      },
      {
        Sid    = "VPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.name_prefix}-argocd-webhook*"]
      }
    ]
  })
}

# ============================================================
# Lambda Security Group
# ============================================================

resource "aws_security_group" "argocd_webhook_lambda" {
  # checkov:skip=CKV_AWS_260:Lambda needs outbound HTTPS to reach ArgoCD internal NLB and Secrets Manager VPC endpoint
  name        = "${local.name_prefix}-argocd-webhook-lambda-sg"
  description = "ArgoCD webhook Lambda - outbound HTTPS to VPC only"
  vpc_id      = aws_vpc.eks.id

  # Outbound HTTPS — reaches ArgoCD internal NLB and Secrets Manager VPC endpoint
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.eks_vpc_cidr]
    description = "HTTPS to VPC (ArgoCD internal NLB + Secrets Manager endpoint)"
  }

  # No inbound rules — API Gateway invokes Lambda via AWS internal service network,
  # not through a network interface. Lambda only needs outbound.

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-lambda-sg" })
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "argocd_webhook" {
  type        = "zip"
  source_file = "${path.module}/lambda/argocd_webhook.py"
  output_path = "${path.module}/lambda/argocd_webhook.zip"
}

resource "aws_lambda_function" "argocd_webhook" {
  # checkov:skip=CKV_AWS_116:DLQ not required — API Gateway returns 500 on Lambda error; GitHub retries automatically
  # checkov:skip=CKV_AWS_117:Lambda is in VPC — X-Ray tracing adds cost without matching benefit for a webhook handler
  function_name = "${local.name_prefix}-argocd-webhook"
  description   = "Validates GitHub webhook signature and triggers ArgoCD sync"
  role          = aws_iam_role.argocd_webhook_lambda.arn
  handler       = "argocd_webhook.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30   # ArgoCD sync call can take up to 15s; 30s gives headroom
  memory_size   = 128  # No compute-heavy work — signature validation + two HTTPS calls

  filename         = data.archive_file.argocd_webhook.output_path
  source_code_hash = data.archive_file.argocd_webhook.output_base64sha256

  # Lambda runs in private subnets so it can reach the ArgoCD internal NLB
  # without ever touching the public internet.
  vpc_config {
    subnet_ids         = aws_subnet.eks_private[*].id
    security_group_ids = [aws_security_group.argocd_webhook_lambda.id]
  }

  environment {
    variables = {
      WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.github_webhook_secret.arn
      ARGOCD_TOKEN_ARN   = aws_secretsmanager_secret.argocd_token.arn
      ARGOCD_URL_ARN     = aws_secretsmanager_secret.argocd_internal_url.arn
    }
  }

  # Encrypt Lambda environment variables at rest
  kms_key_arn = aws_kms_key.secrets.arn

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook" })

  depends_on = [aws_iam_role_policy.argocd_webhook_lambda]
}

resource "aws_cloudwatch_log_group" "argocd_webhook_lambda" {
  # checkov:skip=CKV_AWS_338:30-day retention is sufficient for a webhook handler; longer periods add cost
  # checkov:skip=CKV_AWS_158:KMS CMK for CW log groups requires CloudWatch Logs service principal in key policy; CloudWatch service-side encryption is sufficient for portfolio demo
  name              = "/aws/lambda/${aws_lambda_function.argocd_webhook.function_name}"
  retention_in_days = 30

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-logs" })
}

# ============================================================
# API Gateway HTTP API (v2)
# ============================================================
# HTTP API is used instead of REST API:
#   - Half the price per request
#   - Automatic TLS (AWS-managed cert, no ACM configuration needed)
#   - Built-in HTTPS — no plain HTTP endpoint
#   - Sufficient for a single-route webhook receiver

resource "aws_apigatewayv2_api" "argocd_webhook" {
  name          = "${local.name_prefix}-argocd-webhook"
  description   = "Public HTTPS entry point for GitHub → ArgoCD webhook"
  protocol_type = "HTTP"

  cors_configuration {
    allow_methods = ["POST"]
    allow_origins = ["https://github.com"]
    max_age       = 300
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-api" })
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.argocd_webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.argocd_webhook.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.argocd_webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.argocd_webhook.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.argocd_webhook_api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
      latency        = "$context.integrationLatency"
    })
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-stage" })
}

resource "aws_cloudwatch_log_group" "argocd_webhook_api" {
  # checkov:skip=CKV_AWS_338:30-day retention is sufficient for webhook access logs
  # checkov:skip=CKV_AWS_158:KMS CMK for CW log groups requires CloudWatch Logs service principal in key policy; CloudWatch service-side encryption is sufficient for portfolio demo
  name              = "/aws/apigateway/${local.name_prefix}-argocd-webhook"
  retention_in_days = 30

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-argocd-webhook-api-logs" })
}

# Allow API Gateway to invoke the Lambda function
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.argocd_webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.argocd_webhook.execution_arn}/*/*/webhook"
}
