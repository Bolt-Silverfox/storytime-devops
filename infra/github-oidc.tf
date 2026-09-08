# github-oidc.tf
# GitHub Actions assumes an AWS role via OIDC to push images and trigger a
# redeploy. No long-lived AWS access keys exist in any GitHub secret.
#
# Both the OIDC provider and the deploy role are account-global, so they belong to
# the `shared` workspace (manage_github_oidc = true there, false everywhere else).
# If the AWS account already has a provider for token.actions.githubusercontent.com
# — for example because it is shared with another project — leave this false
# everywhere and reuse the existing one; creating a second one for the same URL
# fails.

data "tls_certificate" "github" {
  count = var.manage_github_oidc ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.manage_github_oidc ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = { Name = "${var.name_prefix}-github-oidc" }
}

# Trust policy: only the enumerated repo+ref subjects. Storytime is many repos,
# so this is a list rather than FateRound's single-repo pair of refs. Exact
# matches, never a wildcard: `repo:org/*` would let any repo in the org — or a
# pull_request from a fork — assume the role.
data "aws_iam_policy_document" "gha_assume" {
  count = var.manage_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_deploy_subjects
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  count              = var.manage_github_oidc ? 1 : 0
  name               = "${var.name_prefix}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_assume[0].json
  tags               = { Name = "${var.name_prefix}-gha-deploy" }
}

# Push images to the Storytime repositories only.
data "aws_iam_policy_document" "gha_ecr" {
  count = var.manage_github_oidc ? 1 : 0

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "gha_ecr" {
  count  = var.manage_github_oidc ? 1 : 0
  name   = "${var.name_prefix}-gha-ecr"
  role   = aws_iam_role.gha_deploy[0].id
  policy = data.aws_iam_policy_document.gha_ecr[0].json
}

# Let CI trigger an in-place redeploy: SSM Run Command, scoped by tag to this
# project's instances and to AWS-RunShellScript only.
#
# NOTE: this is tag-scoped to the whole project, so ONE role can redeploy any
# environment including prod. If prod deploys should need a different role or a
# manual approval, split this per environment — see README "Open decisions".
data "aws_iam_policy_document" "gha_deploy_ssm" {
  count = var.manage_github_oidc ? 1 : 0

  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "SendCommandToProjectInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.name_prefix]
    }
  }

  statement {
    sid       = "SendCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:*:*:document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy_ssm" {
  count  = var.manage_github_oidc ? 1 : 0
  name   = "${var.name_prefix}-gha-deploy-ssm"
  role   = aws_iam_role.gha_deploy[0].id
  policy = data.aws_iam_policy_document.gha_deploy_ssm[0].json
}
