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

# Origin TLS material for the on-box reverse proxy. base64-encoded so multi-line
# PEM survives the SSM/CLI round trip intact.
resource "aws_ssm_parameter" "origin_cert" {
  count = var.create_instance && var.enable_origin_tls ? 1 : 0

  name  = "/${local.prefix}/_proxy/ORIGIN_CERT_B64"
  type  = "SecureString"
  value = base64encode(var.origin_cert)
  tags  = { Name = "${local.prefix}-origin-cert" }
}

resource "aws_ssm_parameter" "origin_key" {
  count = var.create_instance && var.enable_origin_tls ? 1 : 0

  name  = "/${local.prefix}/_proxy/ORIGIN_KEY_B64"
  type  = "SecureString"
  value = base64encode(var.origin_key)
  tags  = { Name = "${local.prefix}-origin-key" }
}
