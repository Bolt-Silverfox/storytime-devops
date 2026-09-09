# ---------------------------------------------------------------------------
# Fail-fast guards.
#
# These exist because the expensive mistakes in a workspace-per-environment
# layout are all "right command, wrong workspace". terraform_data is a built-in
# resource with no provider and no side effects; its preconditions are evaluated
# at plan time, so a mismatch stops the plan instead of surfacing as a diff
# against the wrong environment.
# ---------------------------------------------------------------------------

resource "terraform_data" "guards" {
  input = local.prefix

  lifecycle {
    precondition {
      condition     = terraform.workspace == var.environment
      error_message = "Workspace/environment mismatch: workspace is '${terraform.workspace}' but environment = '${var.environment}'. Run `terraform workspace select ${var.environment}` or pass the matching -var-file."
    }

    precondition {
      condition     = var.environment != "shared" || !var.create_instance
      error_message = "The `shared` workspace owns account-global resources only. Set create_instance = false."
    }

    precondition {
      condition     = var.environment == "shared" || length(local.enabled_services) > 0
      error_message = "No enabled services for environment '${var.environment}'. Populate var.services."
    }

    precondition {
      # Required for BOTH backends. A container Postgres with a blank password is
      # no better than an RDS one, and POSTGRES_PASSWORD="" makes the official
      # image refuse to initialise anyway.
      condition     = !var.create_instance || trimspace(var.db_password) != ""
      error_message = "db_password is required (set TF_VAR_db_password or put it in the gitignored tfvars). It is needed whether Postgres runs as a container or as RDS."
    }

    precondition {
      # The memory budget. Fails the PLAN rather than the box at 03:00.
      condition = (
        !var.create_instance
        || !local.instance_ram_known
        || local.committed_memory_mb <= local.instance_ram_total_mb
      )
      error_message = <<-EOT
        Memory budget exceeded for ${var.instance_type} (${local.instance_ram_total_mb} MiB).
        Committed: ${local.committed_memory_mb} MiB =
          app containers      ${local.app_memory_mb}
        + postgres container  ${local.postgres_container_mb}
        + redis container     ${local.redis_container_mb}
        + host reserve        ${var.host_reserved_mb}
        Either raise instance_type (t3.small 2048 / t3.medium 4096 / t3.large 8192 MiB),
        lower services[*].memory_mb, or disable services you are not actually using.
      EOT
    }

    precondition {
      # An uncapped container can consume the whole box and take everything else
      # with it, which on a single-box stack means the entire platform.
      condition     = !var.create_instance || length(local.uncapped_services) == 0
      error_message = "These services have memory_mb = 0 (uncapped) and cannot be budgeted: ${join(", ", local.uncapped_services)}. On a single shared box an uncapped container can OOM every other service. Set memory_mb for each."
    }

    precondition {
      # A bucket cannot be created and written to if it has no name.
      condition     = !var.create_instance || trimspace(local.backup_bucket) != ""
      error_message = "The backup bucket name resolved to empty. Set backup_bucket_name explicitly."
    }

    precondition {
      condition     = var.tls_mode != "static" || (trimspace(var.tls_certificate) != "" && trimspace(var.tls_private_key) != "")
      error_message = "tls_mode = \"static\" requires both tls_certificate and tls_private_key."
    }

    precondition {
      # ACME needs a monitored contact address. With TLS terminating only on this
      # box, the expiry warning email is the ONLY out-of-band signal that renewal
      # has been failing, and the failure is otherwise invisible until the
      # certificate expires and the whole platform goes dark.
      condition     = !var.create_instance || var.tls_mode != "acme" || trimspace(var.acme_email) != ""
      error_message = "tls_mode = \"acme\" requires acme_email. It is where Let's Encrypt sends expiry and renewal-failure notices, and TLS now terminates nowhere else. Use a monitored alias."
    }

    precondition {
      # Let's Encrypt validates from several unannounced source addresses, so an
      # allowlisted origin cannot complete an HTTP-01 or TLS-ALPN-01 challenge.
      # Caught here rather than as an issuance failure on the box.
      condition     = !var.create_instance || var.tls_mode != "acme" || contains(var.web_ingress_cidrs, "0.0.0.0/0")
      error_message = "tls_mode = \"acme\" requires web_ingress_cidrs to include 0.0.0.0/0: Let's Encrypt validates from unannounced addresses in several regions, so a restricted origin cannot be issued a certificate."
    }

    precondition {
      # A secret name with no value would create an SSM parameter with an empty
      # string, which SSM rejects — and, worse, could blank an existing one.
      condition = alltrue([
        for p in values(local.secret_params) :
        trimspace(lookup(lookup(var.secret_values, p.service, {}), p.key, "")) != ""
      ])
      error_message = "Every name in var.secret_keys must have a non-empty value in var.secret_values. Missing values would blank the corresponding SSM parameter."
    }

    precondition {
      # Two services claiming the same hostname renders two Caddy site blocks for
      # one address. Caddy rejects that ("ambiguous site definition"), the
      # `caddy validate` in user-data fails under `set -e`, and the bootstrap dies
      # before any container starts. Catch it in the plan.
      condition     = length(local.all_hostnames) == length(local.declared_hostnames)
      error_message = "Duplicate hostname(s) across services: ${join(", ", local.duplicate_hostnames)}. Each hostname may be routed to exactly one service."
    }

    precondition {
      # Replicas take consecutive host ports, so two services whose ranges overlap
      # claim the same port. Docker refuses the second bind, and because user-data
      # runs once under `set -euo pipefail` the bootstrap dies with no containers
      # started. Caught in the plan, exactly like the duplicate-hostname case.
      condition     = length(local.duplicate_host_ports) == 0
      error_message = "Host port collision across services: ${join(", ", [for p in local.duplicate_host_ports : tostring(p)])}. Replicas occupy CONSECUTIVE host ports starting at services[*].host_port, so the ranges must not overlap."
    }

    precondition {
      # PORT is applied as a DEFAULT in the container (it no longer overrides SSM),
      # so a config_plain PORT that disagrees with container_port would leave the
      # app listening somewhere the reverse proxy is not pointing.
      condition     = length(local.port_conflicts) == 0
      error_message = "config_plain PORT disagrees with services[*].container_port for: ${join(", ", local.port_conflicts)}. The reverse proxy routes to container_port, so they must match (or omit PORT and let it default)."
    }

    precondition {
      # A production hostname served over plaintext HTTP, with 0.0.0.0/0 ingress,
      # for a service handling children's personal data. There is no edge proxy
      # to terminate TLS instead of the box any more, so this is the only place
      # it can happen: either Caddy does it, or nobody does.
      condition = (
        !contains(["prod", "all"], var.environment)
        || var.tls_mode != "none"
        || var.allow_plaintext_origin
      )
      error_message = "environment = \"${var.environment}\" serves production hostnames with tls_mode = \"none\" — traffic would be plaintext HTTP over the public internet, and there is no proxy in front of this box to terminate TLS instead. Use tls_mode = \"acme\" (or \"static\"), or set allow_plaintext_origin = true to accept cleartext deliberately (only defensible pre-cutover, with no real traffic)."
    }

    precondition {
      condition     = var.redis_mode != "elasticache" || var.environment != "shared"
      error_message = "redis_mode = \"elasticache\" needs a VPC, which the `shared` workspace does not create."
    }
  }
}
