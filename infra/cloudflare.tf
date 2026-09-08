# cloudflare.tf
# Off by default. DNS is hand-edited at Namecheap today (TTL 1800, no CDN, no load
# balancer); moving a zone to Cloudflare is a migration with its own cutover, not
# a side effect of standing up a VPC. Everything here is inert until
# cloudflare_enabled = true.
#
# When enabled, Cloudflare also replaces certbot for public TLS: certificates are
# issued and renewed at the edge, so there is no ACME client on the instance and
# no renewal timer to quietly stop working.

locals {
  cloudflare_in_use = var.cloudflare_enabled || var.restrict_to_cloudflare

  # The provider validates the token's SHAPE (40 characters, [A-Za-z0-9_-]) before
  # it will accept it, so the placeholder has to look like a token. It is never
  # sent anywhere: see the comment on api_token below.
  cloudflare_placeholder_token = "0000000000000000000000000000000000000000"
}

provider "cloudflare" {
  # The Cloudflare provider is configured EAGERLY, and v4 rejects a configuration
  # with no credential at all — so a stack with Cloudflare switched off would fail
  # every `terraform plan` with "must provide exactly one of api_key, api_token or
  # api_user_service_key" despite creating no Cloudflare resources.
  #
  # Therefore:
  #   - token supplied      -> use it;
  #   - Cloudflare in use   -> null, which lets the provider read
  #                            CLOUDFLARE_API_TOKEN from the environment;
  #   - Cloudflare disabled -> a shape-valid placeholder that satisfies the
  #                            provider's presence and format checks. No Cloudflare
  #                            resource or data source exists in that case (every
  #                            one is count = 0), so no API call is ever made and
  #                            the placeholder never leaves the process.
  api_token = (
    var.cloudflare_api_token != ""
    ? var.cloudflare_api_token
    : (local.cloudflare_in_use ? null : local.cloudflare_placeholder_token)
  )
}

# Only fetched when we actually need the ranges to lock the origin down.
data "cloudflare_ip_ranges" "cloudflare" {
  count = var.restrict_to_cloudflare ? 1 : 0
}

locals {
  # Ingress ranges for security.tf.
  web_ingress_ipv4 = (
    var.restrict_to_cloudflare
    ? data.cloudflare_ip_ranges.cloudflare[0].ipv4_cidr_blocks
    : concat(["0.0.0.0/0"], var.extra_web_ingress_cidrs)
  )

  web_ingress_ipv6 = (
    var.restrict_to_cloudflare
    ? data.cloudflare_ip_ranges.cloudflare[0].ipv6_cidr_blocks
    : []
  )
}

# One A record per hostname this environment serves, all pointing at the Elastic
# IP. A records (not CNAMEs) because the address is static.
resource "cloudflare_record" "app" {
  for_each = var.cloudflare_enabled && var.create_instance ? toset(local.all_hostnames) : toset([])

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "A"
  content = aws_eip.app[0].public_ip
  proxied = var.cloudflare_proxied
  comment = "Managed by Terraform — storytime ${var.environment}"
}
