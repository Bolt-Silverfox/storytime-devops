# dns.tf
# ---------------------------------------------------------------------------
# DNS IS NAMECHEAP, AND IT IS EDITED BY HAND. That is a decision, not a gap.
#
# There is no Terraform resource here for an A record, and there is no DNS
# provider in versions.tf, because:
#
#   - The zone is at Namecheap. The community Namecheap providers are
#     unmaintained and wrap an API that requires whitelisting the calling IP
#     address, which a laptop or a CI runner does not have stably. Adopting one
#     would add a credential and a provider that fails in exactly the situation
#     you need it (an incident, from wherever you happen to be).
#   - Cloudflare was evaluated and NOT adopted; the zone is not moving. The
#     previous cloudflare.tf is deleted rather than left switched off, so no
#     plan can ever require a Cloudflare credential again.
#
# So the A record is a MANUAL STEP, written down:
#
#   Namecheap -> Domain List -> Manage -> Advanced DNS -> Host Records
#     Type: A Record   Host: <subdomain>   Value: <the Elastic IP>   TTL: 1800
#
#   `terraform output dns_records_required` prints exactly the rows to enter.
#
# ---------------------------------------------------------------------------
# THE CUTOVER LEVER IS THE ELASTIC IP, NOT THE DNS RECORD.
#
# Remapping an EIP between two instances is a single AWS API call: atomic, a few
# seconds, and reversible by remapping it back. DNS does not change, so
# Namecheap's TTL is irrelevant to cutover and to rollback. See compute.tf
# (aws_eip / aws_eip_association) and docs/migration.md.
#
# The one case where DNS still matters is the FIRST migration, because an EIP can
# only be remapped WITHIN ONE AWS ACCOUNT and the legacy boxes are in a different
# account from this one. That move costs one Namecheap edit and one TTL wait.
# Every migration after it is an EIP remap with no DNS change at all.
# ---------------------------------------------------------------------------

locals {
  # Web ingress for security.tf.
  #
  # 0.0.0.0/0 by default and, with tls_mode = "acme", effectively mandatory:
  # Let's Encrypt validates from unannounced source addresses in several regions
  # (multi-perspective validation), so an allowlist cannot be written for it.
  # guards.tf refuses the combination rather than letting issuance fail on the
  # box at 03:00 with a 90-day fuse already lit.
  web_ingress_ipv4 = distinct(var.web_ingress_cidrs)

  # Deliberately empty: network.tf creates no IPv6 CIDR and the instance has no
  # IPv6 address, so an IPv6 rule would be configuration that looks protective
  # and matches nothing.
  web_ingress_ipv6 = []

  # The rows a human types into Namecheap. Surfaced as an output so the manual
  # step is exact rather than remembered.
  dns_records_required = [
    for h in local.all_hostnames : {
      type  = "A"
      host  = h
      value = local.eip_public_ip
      ttl   = var.namecheap_dns_ttl
    }
  ]
}
