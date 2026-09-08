locals {
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

  # All hostnames this environment answers for, deduped, for DNS records.
  all_hostnames = distinct(flatten([for r in local.routes : r.hostnames]))

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
