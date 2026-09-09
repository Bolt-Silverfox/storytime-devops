# backups.tf
# ===========================================================================
# BACKUPS ARE LOAD-BEARING. DO NOT REMOVE THEM AS AN "OPTIMISATION".
#
# This stack deliberately runs Postgres as a container instead of managed RDS to
# keep the bill near $24/month at fewer than 100 monthly users. Dropping managed
# Postgres means dropping RDS automated backups and point-in-time recovery — so
# the backups have to be re-created here, properly. Without them, self-hosting
# children's personal data under GDPR on a single EBS volume would be reckless.
#
# TWO INDEPENDENT LAYERS, because they fail differently:
#
#   1. Nightly logical dump  — `pg_dump --format=custom` to the S3 bucket below.
#      Survives losing the instance, the volume, the AZ and the region. Allows
#      selective and parallel `pg_restore`. Vulnerable to a dump that succeeds
#      while producing garbage, which is why restore verification exists.
#
#   2. EBS snapshots via DLM  — block-level, whole-volume, taken by AWS with no
#      cooperation from anything running on the box. Survives a corrupted or
#      truncated dump, and a compromised in-guest backup script. Vulnerable to
#      losing the region.
#
# HOW FAILURE SURFACES: the dump script writes a `_status/last-success.json`
# heartbeat object to this bucket ONLY after verifying the uploaded object is
# non-zero. A failure therefore shows up as a STALE HEARTBEAT, readable from
# anywhere without touching the box — which matters, because if the box is dead
# you cannot read its journal. See README -> "Backups".
# ===========================================================================

locals {
  backup_bucket = var.backup_bucket_name != "" ? var.backup_bucket_name : "${local.prefix}-backups"

  # The instance may write under exactly two prefixes, and the IAM policy in
  # iam.tf is scoped to both: `<backup_prefix>/` for the dumps themselves, and
  # `_status/` for the success and restore-verification heartbeats. Nothing else
  # in the bucket is writable by the box, and DeleteObject is not granted at all.
  backup_prefix = "postgres"
}

resource "aws_s3_bucket" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = local.backup_bucket

  # No force_destroy: `terraform destroy` must not be able to take the backups
  # with it. Emptying the bucket has to be a separate, deliberate act.
  force_destroy = false

  tags = { Name = "${local.prefix}-backups" }
}

# Versioning: recovers from an overwrite or a delete, including a malicious one.
resource "aws_s3_bucket_versioning" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# TLS-only. A backup of children's data must never be retrievable over plaintext
# HTTP, even from inside the VPC.
data "aws_iam_policy_document" "backups_bucket" {
  count = var.create_instance ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups[0].arn,
      "${aws_s3_bucket.backups[0].arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id
  policy = data.aws_iam_policy_document.backups_bucket[0].json

  # The public-access block must be in place before a bucket policy is attached,
  # or the policy write can be rejected as potentially-public.
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# Lifecycle: bound the cost of an ever-growing dump history. Current versions
# expire after backup_retention_days; noncurrent versions live a further 7 days so
# an accidental overwrite is still recoverable. Incomplete multipart uploads — a
# failed 3am upload of a large dump — are cleaned up, since they are billed.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count  = var.create_instance ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    id     = "expire-dumps"
    status = "Enabled"

    filter {
      prefix = "${local.backup_prefix}/"
    }

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  # The heartbeat is a single tiny object that is overwritten every night. It must
  # NOT expire — a missing heartbeat and a stale heartbeat should not look alike.
  rule {
    id     = "keep-status-current-only"
    status = "Enabled"

    filter {
      prefix = "_status/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

# ---------------------------------------------------------------------------
# Layer 2: EBS snapshots via Data Lifecycle Manager.
#
# Independent of anything running on the instance: AWS takes these whether or not
# the box is healthy, and a compromised backup script cannot suppress them.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  count = var.create_instance && var.enable_ebs_snapshots ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  count              = var.create_instance && var.enable_ebs_snapshots ? 1 : 0
  name               = "${local.prefix}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume[0].json
  tags               = { Name = "${local.prefix}-dlm" }
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count      = var.create_instance && var.enable_ebs_snapshots ? 1 : 0
  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ebs" {
  count = var.create_instance && var.enable_ebs_snapshots ? 1 : 0

  description        = "Storytime ${var.environment} — scheduled EBS snapshots (backup layer 2)"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # Targets by tag. default_tags in providers.tf puts Stack on every volume, so
    # this needs no volume id — nothing to update when the instance is replaced.
    target_tags = {
      Stack = local.prefix
    }

    schedule {
      name = "daily-${var.ebs_snapshot_retain_count}-retained"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        # After the pg_dump window, so a snapshot captures a completed dump.
        times = [var.ebs_snapshot_time]
      }

      retain_rule {
        count = var.ebs_snapshot_retain_count
      }

      # Tag snapshots so they are attributable and findable during a restore.
      tags_to_add = {
        Name          = "${local.prefix}-dlm"
        SnapshotOfSet = local.prefix
      }

      copy_tags = true
    }
  }

  tags = { Name = "${local.prefix}-dlm-policy" }
}
