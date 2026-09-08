# rds.tf
# ---------------------------------------------------------------------------
# THE EXISTING SHARED DATABASE
#
# Today ONE RDS Postgres instance (emerj-shared-db, eu-west-1) serves dev AND
# staging AND blue AND prod simultaneously. That means a dev migration, a bad
# seed, or a runaway query in staging is a production incident. Splitting it is
# a prerequisite for the environment isolation the rest of this stack assumes.
#
# It is referenced here READ-ONLY. Terraform does not manage, modify, or delete
# it through this data source. Adopting it into Terraform is a separate,
# deliberate `terraform import` (see README -> "Adopting the existing RDS"),
# and it must not be done casually: an import followed by an apply with drifted
# attributes is how live databases get replaced.
# ---------------------------------------------------------------------------

data "aws_db_instance" "shared" {
  count                  = var.shared_db_identifier != "" ? 1 : 0
  db_instance_identifier = var.shared_db_identifier
}

# ---------------------------------------------------------------------------
# A DEDICATED database for this environment (off by default).
#
# Every safety rail is on:
#   - prevent_destroy       : Terraform refuses to plan a destroy at all.
#   - deletion_protection   : AWS refuses the delete even outside Terraform.
#   - skip_final_snapshot=false + a named final snapshot.
#   - ignore_changes on the master password and engine version, so a rotation
#     done out of band (or an AWS auto-minor-upgrade) does not show up as a diff
#     that an apply would "correct" by modifying a live database.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  count = var.create_instance && var.create_database ? 1 : 0

  name       = "${local.prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  count = var.create_instance && var.create_database ? 1 : 0

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

  # NOT publicly accessible — unlike the current shared instance, which resolves
  # to a public address.
  publicly_accessible = false

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "02:00-03:00"
  maintenance_window         = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  # A destroy must leave a restorable copy behind.
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.prefix}-postgres-final"

  performance_insights_enabled    = false
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "${local.prefix}-postgres" }

  lifecycle {
    # Terraform will refuse to even plan the destruction of this resource.
    prevent_destroy = true

    ignore_changes = [
      password,       # rotated out of band; a diff here would reset it
      engine_version, # AWS auto-minor-upgrade moves this
      final_snapshot_identifier,
    ]
  }
}
