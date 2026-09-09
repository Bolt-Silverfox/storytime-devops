# ssm-config.tf
# App configuration lives in SSM Parameter Store under /<prefix>/<service>/<KEY>
# and is read by the instance at boot. This REPLACES .env files on disk: nothing
# in this stack writes a persistent .env, and the instance role can only read its
# own environment's subtree.
#
# Two variables, on purpose:
#   var.config_plain  -> String       (committable, diffable)
#   var.secret_keys   -> the NAMES of the SecureStrings (committable, diffable)
#   var.secret_values -> the values   (sensitive, gitignored, never committed)
#
# The names/values split is what makes the configuration shape reviewable in a
# pull request without ever putting a secret in one. capture/capture-host.sh
# emits var.secret_keys directly for the same reason.

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain_params

  name  = "/${local.prefix}/${each.value.service}/${each.value.key}"
  type  = "String"
  value = each.value.value
  tier  = "Standard"

  tags = {
    Name    = "${local.prefix}-${each.value.service}-${lower(replace(each.value.key, "_", "-"))}"
    Service = each.value.service
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_params

  name  = "/${local.prefix}/${each.value.service}/${each.value.key}"
  type  = "SecureString"
  value = var.secret_values[each.value.service][each.value.key]
  tier  = "Standard"

  tags = {
    Name    = "${local.prefix}-${each.value.service}-${lower(replace(each.value.key, "_", "-"))}"
    Service = each.value.service
  }

  lifecycle {
    precondition {
      condition     = trimspace(lookup(lookup(var.secret_values, each.value.service, {}), each.value.key, "")) != ""
      error_message = "Missing value for secret '${each.value.key}' of service '${each.value.service}'. Add it to var.secret_values (gitignored tfvars) or remove the name from var.secret_keys."
    }
  }
}

# TLS material for the on-box reverse proxy, for tls_mode = "static" only.
# base64-encoded so multi-line PEM survives the SSM/CLI round trip intact.
#
# With the default tls_mode = "acme" there is nothing here: Caddy obtains and
# renews the certificates itself, and the private key never exists anywhere a
# Terraform state file or an SSM parameter could leak it.
resource "aws_ssm_parameter" "tls_certificate" {
  count = var.create_instance && var.tls_mode == "static" ? 1 : 0

  name  = "/${local.prefix}/_proxy/TLS_CERT_B64"
  type  = "SecureString"
  value = base64encode(var.tls_certificate)
  tags  = { Name = "${local.prefix}-tls-cert" }
}

resource "aws_ssm_parameter" "tls_private_key" {
  count = var.create_instance && var.tls_mode == "static" ? 1 : 0

  name  = "/${local.prefix}/_proxy/TLS_KEY_B64"
  type  = "SecureString"
  value = base64encode(var.tls_private_key)
  tags  = { Name = "${local.prefix}-tls-key" }
}

# ---------------------------------------------------------------------------
# Database connection details, under a reserved `_db` service path.
#
# Separate from the per-application parameters because the BACKUP job needs them
# too, and it is not one of the applications. Each app still gets its own
# DATABASE_URL through secret_values — the shape of that string differs per app
# (Prisma, TypeORM and node-postgres do not agree on it), so composing it here
# would produce a stack that looks wired up and is not.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_password" {
  count = var.create_instance ? 1 : 0

  name  = "/${local.prefix}/_db/PASSWORD"
  type  = "SecureString"
  value = var.db_password
  tags  = { Name = "${local.prefix}-db-password" }
}

resource "aws_ssm_parameter" "db_host" {
  count = var.create_instance ? 1 : 0

  name = "/${local.prefix}/_db/HOST"
  type = "String"
  # Container Postgres is reachable from the app containers by container name on
  # the user-defined bridge network; RDS by its endpoint address.
  value = (
    var.use_managed_database
    ? try(aws_db_instance.main[0].address, "pending")
    : "postgres"
  )
  tags = { Name = "${local.prefix}-db-host" }
}

resource "aws_ssm_parameter" "db_name" {
  count = var.create_instance ? 1 : 0

  name  = "/${local.prefix}/_db/NAME"
  type  = "String"
  value = var.db_name
  tags  = { Name = "${local.prefix}-db-name" }
}

resource "aws_ssm_parameter" "db_username" {
  count = var.create_instance ? 1 : 0

  name  = "/${local.prefix}/_db/USERNAME"
  type  = "String"
  value = var.db_username
  tags  = { Name = "${local.prefix}-db-username" }
}
