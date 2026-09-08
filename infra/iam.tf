data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Instance role: pull the service images from ECR, read this environment's SSM
# parameters, decrypt SecureStrings via SSM only, and be reachable through SSM
# Session Manager. No SSH key material exists anywhere in this stack.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_instance" {
  count              = var.create_instance ? 1 : 0
  name               = "${local.prefix}-app-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.prefix}-app-instance" }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = var.create_instance ? 1 : 0
  role       = aws_iam_role.app_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app_instance" {
  # The ECR auth token is inherently account-wide; the pull actions below are
  # scoped to the Storytime repositories only.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = length(local.ecr_repo_arns) > 0 ? local.ecr_repo_arns : ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_prefix}/*"]
  }

  # Read ONLY this environment's parameter subtree. A dev box cannot read prod
  # config, which is precisely what the current shared .env-on-disk model
  # cannot enforce.
  statement {
    sid       = "SsmReadOwnEnvironment"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${local.prefix}/*"]
  }

  # Decrypt SecureStrings, but only through SSM — not arbitrary KMS use.
  statement {
    sid       = "KmsDecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "app_instance" {
  count  = var.create_instance ? 1 : 0
  name   = "${local.prefix}-app-instance"
  role   = aws_iam_role.app_instance[0].id
  policy = data.aws_iam_policy_document.app_instance.json
}

resource "aws_iam_instance_profile" "app" {
  count = var.create_instance ? 1 : 0
  name  = "${local.prefix}-app"
  role  = aws_iam_role.app_instance[0].name
}
