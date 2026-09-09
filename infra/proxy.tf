# proxy.tf
# The on-box reverse proxy config is rendered HERE, by Terraform, rather than
# assembled by a shell script at boot — so `terraform plan` shows the actual
# routing diff before anything is applied. This is the piece that replaces the
# hand-edited nginx vhosts which today exist only on the boxes' disks and are in
# no repository at all.
#
# Caddy rather than nginx because it needs no separate certbot: with the default
# tls_mode = "acme" it obtains and renews Let's Encrypt certificates itself, as
# part of the same process that serves the traffic, so there is no renewal timer
# to stop working independently of the thing it renews for.
#
# THIS IS NOW THE ONLY PLACE PUBLIC TLS EXISTS. There is no Cloudflare edge in
# front of the box (see dns.tf), so a Caddy that cannot get a certificate is an
# outage, not a degraded mode. What to check when that happens is in
# infra/README.md -> "When TLS breaks".
#
# Behaviours carried over verbatim from the current nginx configuration:
#   - proxy_buffering off      -> `flush_interval -1` on SSE routes
#   - proxy_read_timeout 3600s -> `read_timeout` on the http transport
#   - client_max_body_size 25m -> `request_body { max_size ... }`

locals {
  caddyfile = templatefile("${path.module}/templates/Caddyfile.tftpl", {
    routes            = local.routes
    tls_mode          = var.tls_mode
    acme_email        = var.acme_email
    acme_ca_directory = var.acme_ca_directory
    environment       = var.environment
  })
}
