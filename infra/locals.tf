locals {
  # ---------------------------------------------------------------------------
  # Memory budget.
  #
  # The whole platform runs on ONE small box, and that box also hosts Postgres and
  # Redis. On a t3.small (2 GiB) there is roughly 1.2 GiB left for application
  # containers after the OS, dockerd, the SSM agent and Caddy. Overcommitting does
  # not fail at apply time — it fails at 03:00 when the kernel OOM-kills whichever
  # container it likes least. guards.tf turns that into a plan-time error.
  #
  # RAM per instance type, in MiB. Extend as needed, or set
  # var.instance_ram_mb_override; an unknown type simply skips the check.
  # ---------------------------------------------------------------------------
  instance_ram_mb = {
    "t3.micro"   = 1024
    "t3.small"   = 2048
    "t3.medium"  = 4096
    "t3.large"   = 8192
    "t3.xlarge"  = 16384
    "t4g.small"  = 2048
    "t4g.medium" = 4096
    "t4g.large"  = 8192
    "m6i.large"  = 8192
    "m7g.large"  = 8192
  }

  instance_ram_known = (
    var.instance_ram_mb_override > 0
    || contains(keys(local.instance_ram_mb), var.instance_type)
  )

  instance_ram_total_mb = (
    var.instance_ram_mb_override > 0
    ? var.instance_ram_mb_override
    : lookup(local.instance_ram_mb, var.instance_type, 0)
  )

  # Data-tier containers only count when they actually run on the box.
  postgres_container_mb = var.use_managed_database ? 0 : var.postgres_memory_mb
  redis_container_mb    = var.redis_mode == "container" ? var.redis_memory_mb : 0

  # A service with memory_mb = 0 is UNCAPPED, so the budget cannot be checked
  # against it. Counted separately and reported, rather than silently treated as 0.
  uncapped_services = [for k, v in local.enabled_services : k if v.memory_mb == 0]

  app_memory_mb = sum(concat([0], [
    for c in local.containers : c.memory_mb
  ]))

  committed_memory_mb = (
    local.app_memory_mb
    + local.postgres_container_mb
    + local.redis_container_mb
    + var.host_reserved_mb
  )

  # Every resource name and every SSM path is namespaced by project+environment,
  # so four workspaces can coexist in one account without colliding.
  prefix = "${var.name_prefix}-${var.environment}"

  # Services actually deployed in this environment.
  enabled_services = { for k, v in var.services : k => v if v.enabled }

  # One entry per running container: replicas are separate containers on
  # consecutive host ports, load-balanced by the on-box proxy. This is the
  # container-world equivalent of PM2 cluster mode.
  containers = flatten([
    for name, svc in local.enabled_services : [
      for i in range(svc.replicas) : {
        service        = name
        replica        = i
        container_name = svc.replicas > 1 ? "${name}-${i}" : name
        host_port      = svc.host_port + i
        container_port = svc.container_port
        memory_mb      = svc.memory_mb
        extra_env      = svc.extra_env
        health_path    = svc.health_path
      }
    ]
  ])

  # hostname -> upstream set, for the reverse proxy vhosts.
  routes = [
    for name, svc in local.enabled_services : {
      service       = name
      hostnames     = svc.hostnames
      upstreams     = [for i in range(svc.replicas) : "127.0.0.1:${svc.host_port + i}"]
      sse           = svc.sse
      max_body_size = svc.max_body_size
      read_timeout  = svc.read_timeout
      health_path   = svc.health_path
    } if length(svc.hostnames) > 0
  ]

  # All hostnames this stack answers for, deduped, for DNS records.
  all_hostnames = distinct(flatten([for r in local.routes : r.hostnames]))

  # Undeduped, so a collision between two services is detectable in guards.tf.
  declared_hostnames = flatten([for r in local.routes : r.hostnames])

  duplicate_hostnames = distinct([
    for h in local.declared_hostnames : h
    if length([for x in local.declared_hostnames : x if x == h]) > 1
  ])

  # Services whose config_plain PORT contradicts their container_port. PORT is now
  # applied as a default rather than an override, so a mismatch would leave the app
  # listening where the proxy is not looking.
  port_conflicts = [
    for name, svc in local.enabled_services : name
    if lookup(lookup(var.config_plain, name, {}), "PORT", tostring(svc.container_port)) != tostring(svc.container_port)
  ]

  # ---------------------------------------------------------------------------
  # SSM parameter flattening.
  #
  # Names and values are kept in SEPARATE variables on purpose: var.secret_keys
  # (names) is non-sensitive so it can be committed and diffed, and it is what
  # for_each iterates over. for_each cannot depend on a sensitive value, so
  # deriving the iteration from names sidesteps that entirely instead of
  # laundering it through nonsensitive().
  # ---------------------------------------------------------------------------
  plain_params = merge([
    for svc, kv in var.config_plain : {
      for k, v in kv : "${svc}/${k}" => { service = svc, key = k, value = v }
    }
  ]...)

  secret_params = merge([
    for svc, keys in var.secret_keys : {
      for k in keys : "${svc}/${k}" => { service = svc, key = k }
    }
  ]...)
}
