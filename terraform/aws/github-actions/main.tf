# GitHub Actions OIDC — lets CI assume an AWS IAM role using a short-lived
# JWT token minted by GitHub. No static AWS keys stored in GitHub Secrets.

locals {
  account_id       = data.aws_caller_identity.current.account_id
  oidc_provider_url = "token.actions.githubusercontent.com"
}

# ── OIDC Identity Provider ────────────────────────────────────────────────────
# Registers GitHub's token endpoint as a trusted identity provider in this
# AWS account. AWS will verify JWTs are genuinely issued by GitHub before
# granting credentials.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://${local.oidc_provider_url}"

  # sts.amazonaws.com is the audience GitHub Actions sends in the JWT.
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint — identifies their TLS cert chain to AWS.
  # This value is stable; only changes if GitHub rotates their root CA.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name    = "github-actions-oidc"
    project = "payflow"
  }
}

# ── IAM Role ─────────────────────────────────────────────────────────────────
# GitHub Actions workflows assume this role via sts:AssumeRoleWithWebIdentity.
# The trust policy scopes access to this specific GitHub repo only.

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this repo only — any branch or event (PR, push, etc.)
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "payflow-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Name    = "payflow-github-actions-role"
    project = "payflow"
  }
}

# ── ECR Policy ────────────────────────────────────────────────────────────────
# Allows CI to log in to ECR and push images for all 6 PayFlow services.
# GetAuthorizationToken must be * (it is a global ECR action, not per-repo).

data "aws_iam_policy_document" "ecr" {
  # ECR login token — required before any docker push/pull
  statement {
    sid       = "ECRLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Image push permissions scoped to payflow ECR repos only
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.ecr_cluster_name}/*"
    ]
  }
}

resource "aws_iam_policy" "ecr" {
  name   = "payflow-github-actions-ecr-policy"
  policy = data.aws_iam_policy_document.ecr.json

  tags = {
    Name    = "payflow-github-actions-ecr-policy"
    project = "payflow"
  }
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.ecr.arn
}
