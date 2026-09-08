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
      condition     = !var.create_database || trimspace(var.db_password) != ""
      error_message = "create_database = true requires db_password (set TF_VAR_db_password or put it in the gitignored tfvars)."
    }

    precondition {
      condition     = !var.enable_origin_tls || (trimspace(var.origin_cert) != "" && trimspace(var.origin_key) != "")
      error_message = "enable_origin_tls = true requires both origin_cert and origin_key."
    }

    precondition {
      # Locking the origin to Cloudflare only works if traffic actually arrives
      # via a proxied Cloudflare record; otherwise the box is unreachable.
      condition     = !var.restrict_to_cloudflare || (var.cloudflare_enabled && var.cloudflare_proxied)
      error_message = "restrict_to_cloudflare = true requires cloudflare_enabled = true and cloudflare_proxied = true, or the origin becomes unreachable."
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
      condition     = var.redis_mode != "elasticache" || var.environment != "shared"
      error_message = "redis_mode = \"elasticache\" needs a VPC, which the `shared` workspace does not create."
    }
  }
}
