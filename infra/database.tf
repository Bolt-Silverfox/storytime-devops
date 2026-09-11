# database.tf
# ---------------------------------------------------------------------------
# Two backends, one variable: `use_managed_database`.
#
#   false (DEFAULT) -> Postgres runs as a container on the app box, provisioned by
#                      templates/user-data.sh.tftpl. Nothing is created here.
#   true            -> a managed RDS instance, below.
#
# The default is the container because managed RDS roughly doubles the bill at
# fewer than 100 monthly users (db.t4g.micro ~$12.41/mo on top of a ~$16.64
# instance). The switch exists so that moving to RDS later is a variable flip plus
# a data migration rather than a rewrite: the application reads its connection
# string from SSM either way, and `outputs.tf` reports whichever endpoint is live.
#
# WHAT THE DEFAULT COSTS, stated plainly: a container's data directory lives on
# the instance's EBS volume, so Postgres is the ONE thing on this box that is not
# disposable. Everything else — images, config, DNS — can be recreated from
# elsewhere. That trade is only defensible because backups.tf makes backups real
# and mandatory: nightly pg_dump to a versioned, encrypted S3 bucket, plus
# independent DLM EBS snapshots. This is children's personal data under GDPR.
# ---------------------------------------------------------------------------

# The existing shared instance, READ-ONLY, so its endpoint is visible while a
# migration is in flight. Terraform does not manage or modify it.
data "aws_db_instance" "shared" {
  count                  = var.shared_db_identifier != "" ? 1 : 0
  db_instance_identifier = var.shared_db_identifier
}

# ---------------------------------------------------------------------------
# Managed RDS (only when use_managed_database = true).
#
# Every rail is on: prevent_destroy so Terraform will not even PLAN a destroy,
# deletion_protection so AWS refuses it outside Terraform too, a mandatory final
# snapshot, and ignore_changes on password and engine_version so an out-of-band
# rotation or an AWS auto-minor upgrade never appears as a diff that an apply
# would "correct" against a live database.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  count = var.create_instance && var.use_managed_database ? 1 : 0

  name       = "${local.prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  count = var.create_instance && var.use_managed_database ? 1 : 0

  identifier     = "${local.prefix}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage > 0 ? var.db_max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.data[0].id]

  # Not publicly accessible — unlike the current shared instance, which resolves
  # to a public address.
  publicly_accessible = false

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "02:00-03:00"
  maintenance_window         = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.prefix}-postgres-final"

  performance_insights_enabled    = false
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "${local.prefix}-postgres" }

  lifecycle {
    prevent_destroy = true

    ignore_changes = [
      password,
      engine_version,
      final_snapshot_identifier,
    ]
  }
}
