# redis.tf
# ---------------------------------------------------------------------------
# Redis is not optional for Storytime. BullMQ backs the email, push,
# story-generation and TTS-batch queues, and @keyv/redis backs caching and guest
# sessions. A queue is DURABLE STATE: an evicted or lost job is an email never
# sent or a narration never produced, with no error anywhere.
#
# Today all environments share one unmanaged Redis on the box, with blue merely
# using logical DB /3. Logical DBs are namespacing, not isolation: one FLUSHALL,
# one eviction storm, or one `maxmemory` breach affects every environment.
#
# TRADE-OFF, chosen per environment via var.redis_mode:
#
#   container   - a redis container beside the app containers. Free, one less
#                 moving part, and identical in behaviour to today. But the data
#                 lives on the instance's EBS volume, so replacing the box (which
#                 this stack does on every user_data change) DROPS EVERY QUEUED
#                 JOB. Fine for dev and blue.
#
#   elasticache - managed replication group. Survives instance replacement, has
#                 automatic snapshots, encryption in transit and at rest, and a
#                 real maxmemory policy. Costs roughly a cache.t4g.micro per
#                 environment. This is the right answer for staging and prod,
#                 where a dropped queue is lost user-visible work.
#
#   external    - managed elsewhere; put the connection string in secret_values.
#
# `noeviction` is the default policy on purpose: an allkeys-lru cache that evicts
# a BullMQ job hash loses the job silently, whereas noeviction makes Redis reject
# writes when full — loud, and recoverable.
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  count = var.create_instance && var.redis_mode == "elasticache" ? 1 : 0

  name       = "${local.prefix}-redis"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-redis-subnet-group" }
}

resource "aws_elasticache_parameter_group" "main" {
  count = var.create_instance && var.redis_mode == "elasticache" ? 1 : 0

  name = "${local.prefix}-redis"
  # Pinned to the redis7 family; var.redis_engine_version is validated to 7.x so
  # the two cannot drift apart into an apply-time rejection.
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = var.redis_maxmemory_policy
  }

  tags = { Name = "${local.prefix}-redis-params" }
}

resource "aws_elasticache_replication_group" "main" {
  count = var.create_instance && var.redis_mode == "elasticache" ? 1 : 0

  replication_group_id = "${local.prefix}-redis"
  description          = "Storytime ${var.environment} — BullMQ queues + cache"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  parameter_group_name = aws_elasticache_parameter_group.main[0].name
  port                 = 6379

  # Single node to start. Raise num_cache_clusters and set
  # automatic_failover_enabled = true when a queue outage stops being tolerable.
  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.main[0].name
  security_group_ids = [aws_security_group.data[0].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # Daily snapshots: a queue with pending jobs is worth restoring.
  snapshot_retention_limit = 5
  snapshot_window          = "01:00-02:00"

  maintenance_window         = "sun:04:30-sun:05:30"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = { Name = "${local.prefix}-redis" }

  lifecycle {
    ignore_changes = [engine_version]
  }
}

locals {
  # Where the app should point. With redis_mode = "container" the redis container
  # shares the host network namespace via a published port on loopback, so the
  # app containers reach it at 127.0.0.1:6379.
  #
  # NOTE: this is surfaced as an OUTPUT for the operator to place into
  # config_plain/secret_values. It is deliberately not injected automatically:
  # the apps read REDIS_URL (and friends) whose exact names differ per app, and
  # guessing them here would produce a stack that looks wired up and is not.
  redis_endpoint = (
    var.redis_mode == "elasticache" && var.create_instance
    ? try("rediss://${aws_elasticache_replication_group.main[0].primary_endpoint_address}:6379", "")
    : var.redis_mode == "container" ? "redis://127.0.0.1:6379" : ""
  )
}
