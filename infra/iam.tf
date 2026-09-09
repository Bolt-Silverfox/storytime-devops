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

  # Backups: write ONLY under this stack's own prefix in its own bucket. No
  # wildcard S3 access, no ListAllMyBuckets, no read of anyone else's prefix.
  # ListBucket is needed so the restore/verify path can find the newest dump, and
  # is itself constrained to the same prefix by a condition.
  dynamic "statement" {
    for_each = var.create_instance ? [1] : []
    content {
      sid = "BackupWriteOwnPrefix"
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = [
        "${aws_s3_bucket.backups[0].arn}/${local.backup_prefix}/*",
        "${aws_s3_bucket.backups[0].arn}/_status/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.create_instance ? [1] : []
    content {
      sid       = "BackupListOwnPrefix"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.backups[0].arn]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values = [
          "${local.backup_prefix}/*",
          "_status/*",
        ]
      }
    }
  }

  # Deliberately NOT granted: s3:DeleteObject. Expiry is the bucket lifecycle
  # rule's job, so a compromised box cannot destroy the backup history.

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
