# proxy.tf
# The on-box reverse proxy config is rendered HERE, by Terraform, rather than
# assembled by a shell script at boot — so `terraform plan` shows the actual
# routing diff before anything is applied. This is the piece that replaces the
# hand-edited nginx vhosts which today exist only on the boxes' disks and are in
# no repository at all.
#
# Caddy rather than nginx because it needs no separate certbot: with
# enable_origin_tls it serves a Cloudflare Origin Certificate supplied from SSM,
# and with it off it serves plain HTTP behind Cloudflare's edge. Either way there
# is no Let's Encrypt renewal timer to silently stop working.
#
# Behaviours carried over verbatim from the current nginx configuration:
#   - proxy_buffering off      -> `flush_interval -1` on SSE routes
#   - proxy_read_timeout 3600s -> `read_timeout` on the http transport
#   - client_max_body_size 25m -> `request_body { max_size ... }`

locals {
  caddyfile = templatefile("${path.module}/templates/Caddyfile.tftpl", {
    routes            = local.routes
    enable_origin_tls = var.enable_origin_tls
    environment       = var.environment
  })
}
