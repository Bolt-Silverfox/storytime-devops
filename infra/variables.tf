# ---------------------------------------------------------------------------
# Identity / placement
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = <<-EOT
    AWS region to deploy into.

    DEFAULT IS eu-west-1 ON PURPOSE. The existing Storytime infrastructure
    (both EC2 hosts and the shared RDS instance) lives in eu-west-1, and
    Storytime processes children's personal data and ships GDPR data-export
    features — so region is a DATA-RESIDENCY / COMPLIANCE decision, not a
    latency preference. Do not "align with FateRound" by moving this to
    us-east-1 without a signed-off decision. See README -> "Open decisions".
  EOT
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Project prefix for every resource name and SSM path."
  type        = string
  default     = "storytime"
}

variable "environment" {
  description = <<-EOT
    Which stack this workspace represents.

    `all` is the DEFAULT and the initial deployment: a SINGLE box hosting every
    environment's containers side by side. Storytime has fewer than 100 monthly
    users, and one instance per environment was rejected as overbuilt for that.
    See README -> "One box, and when to stop using one box".

    The other values exist so an environment can be PEELED OFF onto its own box
    later without rewriting anything: create a new workspace, set
    `environment = "prod"`, give it only the prod services, and flip the
    Cloudflare records. That is the whole migration.

    `shared` is not a runtime stack; it exists only if you later want the
    account-global resources (ECR repositories, the GitHub OIDC provider) split
    away from the runtime stacks. With `all` they belong to the single stack.
  EOT
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "shared", "dev", "staging", "blue", "prod"], var.environment)
    error_message = "environment must be one of: all, shared, dev, staging, blue, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for this environment's VPC. Keep environments non-overlapping so they can be peered later if ever needed."
  type        = string
  default     = "10.40.0.0/16"
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the application host. A VARIABLE, not a hardcoded
    resource attribute, so resizing is a one-line change and a migration never
    has to hunt for it.

    Default `t3.small` (2 vCPU, 2 GiB, ~$16.64/mo in eu-west-1) — deliberately
    minimal, to scale UP from rather than down to.

    BUDGET REALITY, and `guards.tf` enforces it: the box also runs Postgres and
    Redis as containers. On 2 GiB that leaves roughly 1.2 GiB for application
    containers, which is two small Node services — not eighteen. If you put
    dev + staging + prod of every service on one box you need t3.medium (4 GiB)
    or t3.large (8 GiB). The plan will tell you rather than the box OOM-killing
    at 03:00.

      t3.small   2 GiB   ~$16.64/mo
      t3.medium  4 GiB   ~$33.29/mo
      t3.large   8 GiB   ~$66.58/mo
  EOT
  type        = string
  default     = "t3.small"
}

variable "instance_ram_mb_override" {
  description = <<-EOT
    RAM in MiB for `instance_type`, for the memory-budget guard. Only needed for
    an instance type not in `locals.instance_ram_mb`; 0 means "look it up, and
    skip the check if unknown". Never used to size a resource.
  EOT
  type        = number
  default     = 0
}

variable "host_reserved_mb" {
  description = "RAM held back for the OS, dockerd, the SSM agent and Caddy, and excluded from the container memory budget."
  type        = number
  default     = 400
}

variable "root_volume_size" {
  description = <<-EOT
    Root EBS volume size (GiB), always encrypted. Holds the container images, the
    Postgres data directory when `use_managed_database = false`, and logs.
    `docker image prune -af` runs on every redeploy so images stay bounded.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB (container images + Postgres data + logs)."
  }
}

variable "create_instance" {
  description = "Create the application host. Set false in the `shared` workspace, which only owns account-global resources."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Services (the multi-container model)
# ---------------------------------------------------------------------------

variable "services" {
  description = <<-EOT
    The containers this environment runs, keyed by short service name
    (e.g. "api", "web", "admin", "waitlist-api", "waitlist-web", "logs").

    - container_port : port the process listens on INSIDE the container.
    - host_port      : first host port published. With replicas > 1, replica i
                       publishes host_port + i.
    - hostnames      : public hostnames routed to this service by the on-box
                       reverse proxy (Caddy). Cloudflare DNS records are created
                       for these when cloudflare_enabled = true.
    - replicas       : horizontal copies on the box, load-balanced round-robin by
                       Caddy. This is the container-world replacement for PM2
                       cluster mode (prod API runs max(2, cpus-1) workers today).
    - sse            : true if the service streams Server-Sent Events. Disables
                       response buffering and raises the proxy read timeout, which
                       is what the current nginx `proxy_buffering off` +
                       `proxy_read_timeout 3600s` vhosts exist to do.
    - max_body_size  : request body cap; mirrors today's `client_max_body_size 25m`.
    - health_path    : path the proxy/bootstrap uses for a readiness probe.
    - image_tag      : image tag to run. Prefer an immutable tag (the git SHA)
                       over "latest" so a redeploy is deterministic.
    - enabled        : set false to keep a service defined but not deployed.
  EOT
  type = map(object({
    container_port = number
    host_port      = number
    hostnames      = optional(list(string), [])
    replicas       = optional(number, 1)
    sse            = optional(bool, false)
    max_body_size  = optional(string, "25m")
    read_timeout   = optional(string, "3600s")
    health_path    = optional(string, "/")
    image_tag      = optional(string, "latest")
    enabled        = optional(bool, true)
    memory_mb      = optional(number, 0)
    extra_env      = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in var.services :
      s.container_port > 0 && s.container_port <= 65535 &&
      s.host_port > 0 && s.host_port <= 65535 &&
      s.replicas >= 1
    ])
    error_message = "Each service needs container_port and host_port in 1-65535 and replicas >= 1."
  }

  validation {
    # Two services publishing the same host port would silently fight over it.
    # Account for replicas, which consume host_port .. host_port + replicas - 1.
    condition = length(flatten([
      for s in var.services : range(s.host_port, s.host_port + s.replicas)
      ])) == length(distinct(flatten([
        for s in var.services : range(s.host_port, s.host_port + s.replicas)
    ])))
    error_message = "Host port ranges overlap between services (remember replicas consume host_port .. host_port + replicas - 1)."
  }

  validation {
    condition     = alltrue([for k in keys(var.services) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", k))])
    error_message = "Service keys must be lowercase alphanumeric with internal hyphens (they become ECR repo and SSM path segments)."
  }
}

variable "ecr_repository_prefix" {
  description = "Namespace for the shared ECR repositories. Repos are named <ecr_repository_prefix>/<service>."
  type        = string
  default     = "storytime"
}

variable "manage_shared_ecr" {
  description = <<-EOT
    Create the ECR repositories. ECR repos are shared across environments so an
    image is built ONCE and promoted dev -> staging -> prod by tag. Exactly one
    workspace (the `shared` one) must set this true; every other workspace reads
    the repos through a data source, so apply `shared` first.
  EOT
  type        = bool
  default     = false
}

variable "ecr_keep_last_images" {
  description = "How many images to retain per repository before the lifecycle policy expires them."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# App configuration (SSM Parameter Store)
# ---------------------------------------------------------------------------

variable "config_plain" {
  description = <<-EOT
    Non-secret configuration, per service: { service = { KEY = "value" } }.
    Written to SSM as `String` parameters under /<prefix>/<service>/<KEY>.
  EOT
  type        = map(map(string))
  default     = {}
}

variable "secret_keys" {
  description = <<-EOT
    NAMES ONLY of the secret configuration each service needs:
    { service = ["DATABASE_URL", "JWT_SECRET", ...] }.

    Deliberately split from the values so the SHAPE of the configuration is
    reviewable, diffable and committable while the values never are. The
    capture script (capture/capture-host.sh) emits exactly this shape — names
    only, never values — so its output can be pasted straight in here.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "secret_values" {
  description = <<-EOT
    Values for the names declared in var.secret_keys:
    { service = { KEY = "value" } }. Written to SSM as `SecureString`.

    Supply these from a GITIGNORED terraform.<env>.tfvars, or from TF_VAR_
    environment variables in a break-glass session. Never commit them.
  EOT
  type        = map(map(string))
  default     = {}
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "use_managed_database" {
  description = <<-EOT
    false (DEFAULT) -> Postgres runs as a CONTAINER on the app box.
    true            -> a managed RDS instance is created instead.

    Managed RDS would roughly double the bill at this user count
    (db.t4g.micro ~$12.41/mo on top of a $16.64 instance), so the default is the
    container. The switch exists so moving to RDS later is a VARIABLE FLIP plus a
    data migration, not a rewrite: the app reads its connection string from SSM
    either way, and `outputs.tf` reports whichever endpoint is live.

    THE PRICE OF THE DEFAULT: a container's data lives on the instance's EBS
    volume, so Postgres is the one thing on this box that is not disposable. That
    is only defensible because backups are mandatory and real — nightly pg_dump to
    a versioned encrypted S3 bucket plus DLM EBS snapshots (see backups.tf). This
    is children's personal data under GDPR. Do not remove the backups.
  EOT
  type        = bool
  default     = false
}

variable "postgres_image" {
  description = "Image used when use_managed_database = false. Pinned to a minor line, never `latest` — an unpinned major upgrade would refuse to start against an existing data directory."
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:16.4-alpine"
}

variable "postgres_memory_mb" {
  description = "Memory limit for the Postgres container. Counts against the instance memory budget enforced in guards.tf."
  type        = number
  default     = 512
}

variable "redis_memory_mb" {
  description = "Memory limit for the Redis container. Counts against the instance memory budget enforced in guards.tf."
  type        = number
  default     = 192
}

variable "db_name" {
  description = "Initial database name, for either backend."
  type        = string
  default     = "storytime"
}

variable "db_username" {
  description = "Database superuser/master username, for either backend."
  type        = string
  default     = "storytime"
}

variable "db_password" {
  description = "Database password. REQUIRED for both backends — a container Postgres with a blank password is as bad as an RDS one. Supply via TF_VAR_db_password or a gitignored tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "shared_db_identifier" {
  description = <<-EOT
    Identifier of the EXISTING shared RDS instance (today: the legacy shared RDS instance in
    eu-west-1, serving dev AND staging AND blue AND prod at the same time).

    When set, a READ-ONLY data source looks it up so its endpoint is visible in
    outputs during a migration. Terraform never modifies it. Leave "" to skip.
  EOT
  type        = string
  default     = ""
}

# --- only used when use_managed_database = true -----------------------------

variable "db_engine_version" {
  description = "Postgres engine version for a managed instance. Confirm it matches what the container/source database runs before migrating."
  type        = string
  default     = "16.4"
}

variable "db_instance_class" {
  description = "Managed instance class. eu-west-1: db.t4g.micro ~$12.41/mo, db.t4g.small ~$25.55, db.t4g.medium ~$50.37."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage (GiB) for a managed instance."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB) for a managed instance. 0 disables autoscaling."
  type        = number
  default     = 100
}

variable "db_backup_retention_days" {
  description = "Automated backup retention for a managed instance. Never 0 — 0 disables backups AND point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "db_backup_retention_days must be >= 1; 0 disables automated backups and PITR."
  }
}

# ---------------------------------------------------------------------------
# Backups — NOT OPTIONAL. See use_managed_database above for why.
# ---------------------------------------------------------------------------

variable "backup_bucket_name" {
  description = <<-EOT
    S3 bucket for nightly pg_dump output. Created by this configuration
    (versioned, SSE-encrypted, public-access-blocked, TLS-only, lifecycle-expired)
    — unlike the Terraform STATE bucket, there is no chicken-and-egg here.

    Empty means "<name_prefix>-<environment>-backups". Bucket names are globally
    unique; if that is taken, set one explicitly.
  EOT
  type        = string
  default     = ""
}

variable "backup_schedule_calendar" {
  description = "systemd OnCalendar expression for the nightly dump. Default 02:15 UTC — after the daily traffic trough, before the DLM snapshot window."
  type        = string
  default     = "*-*-* 02:15:00 UTC"
}

variable "backup_retention_days" {
  description = "Days to keep a dump before the S3 lifecycle rule expires it. Noncurrent versions are kept a further 7 days, so an overwrite is recoverable."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_days >= 7
    error_message = "backup_retention_days must be at least 7: a shorter window cannot survive an unnoticed weekend failure."
  }
}

variable "enable_ebs_snapshots" {
  description = <<-EOT
    Create a DLM policy taking scheduled EBS snapshots of this stack's volumes —
    an INDEPENDENT second layer, so a corrupted or truncated pg_dump is not a
    total loss. On by default; the two layers fail differently on purpose.
  EOT
  type        = bool
  default     = true
}

variable "ebs_snapshot_time" {
  description = "UTC HH:MM start of the DLM snapshot window. After the pg_dump window so a snapshot captures a completed dump."
  type        = string
  default     = "03:30"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.ebs_snapshot_time))
    error_message = "ebs_snapshot_time must be UTC HH:MM, 24-hour."
  }
}

variable "ebs_snapshot_retain_count" {
  description = "How many EBS snapshots DLM keeps."
  type        = number
  default     = 7

  validation {
    condition     = var.ebs_snapshot_retain_count >= 1 && var.ebs_snapshot_retain_count <= 1000
    error_message = "ebs_snapshot_retain_count must be between 1 and 1000."
  }
}

variable "enable_restore_verification" {
  description = <<-EOT
    Install a weekly job that restores the LATEST dump into a THROWAWAY Postgres
    container and asserts the table count is above `restore_verify_min_tables`.

    This is what turns the backup from an assumption into something proven. It
    touches neither the live database nor the live container: it starts a separate
    container on an unpublished port, restores into it, counts, and destroys it.
  EOT
  type        = bool
  default     = true
}

variable "restore_verify_min_tables" {
  description = "Minimum table count a restored dump must contain for verification to pass. A dump that restores but is nearly empty is a failed backup, not a successful one."
  type        = number
  default     = 5
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------

variable "redis_mode" {
  description = <<-EOT
    How this environment gets Redis. Storytime genuinely needs it: BullMQ backs
    the email, push, story-generation and TTS-batch queues, and @keyv/redis backs
    caching and guest sessions.

      "container"   - a redis container on the same box. Cheapest, matches today's
                      unmanaged local Redis. Data lives on the instance, so a box
                      replacement DROPS EVERY QUEUED JOB (unsent emails, pending
                      TTS batches). Acceptable for dev/blue.
      "elasticache" - a managed ElastiCache replication group: survives instance
                      replacement, has snapshots, encryption in transit/at rest.
                      Costs money and adds a subnet group + SG. Right answer for
                      staging/prod, where losing a queue loses user-visible work.
      "external"    - neither; the app points at something you manage elsewhere
                      (set the connection string in secret_values).

    Note: today ALL environments share one local Redis and blue merely uses
    logical DB /3. Logical DBs are not isolation — FLUSHALL or an eviction storm
    in one environment takes out the others.
  EOT
  type        = string
  default     = "container"

  validation {
    condition     = contains(["container", "elasticache", "external"], var.redis_mode)
    error_message = "redis_mode must be one of: container, elasticache, external."
  }
}

variable "redis_container_image" {
  description = "Image used when redis_mode = \"container\". Pinned by digest-able tag rather than `latest`."
  type        = string
  default     = "public.ecr.aws/docker/library/redis:7.4-alpine"
}

variable "redis_node_type" {
  description = "Node type when redis_mode = \"elasticache\"."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_engine_version" {
  description = <<-EOT
    Engine version when redis_mode = "elasticache".

    Constrained to 7.x because the parameter group in redis.tf declares
    family = "redis7"; a 6.x version here would be rejected by ElastiCache at
    apply time. Redis 6 is also end-of-life, so widening this is not worth the
    version-to-family mapping it would need.
  EOT
  type        = string
  default     = "7.1"

  validation {
    condition     = can(regex("^7(\\.[0-9]+)*$", var.redis_engine_version))
    error_message = "redis_engine_version must be a 7.x version (the ElastiCache parameter group family is redis7)."
  }
}

variable "redis_maxmemory_policy" {
  description = <<-EOT
    Eviction policy. MUST NOT be a volatile-*/allkeys-* policy that can evict
    BullMQ job hashes: an evicted job is a silently lost job. `noeviction` makes
    Redis reject writes when full instead, which is loud and recoverable.
  EOT
  type        = string
  default     = "noeviction"
}

# ---------------------------------------------------------------------------
# Edge / DNS
# ---------------------------------------------------------------------------

variable "cloudflare_enabled" {
  description = "Manage DNS records in Cloudflare. Off by default: DNS is hand-edited at Namecheap today, and cutting over is a deliberate migration."
  type        = bool
  default     = false
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped DNS:Edit. Falls back to the CLOUDFLARE_API_TOKEN env var when empty; keep it out of tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the Storytime domain."
  type        = string
  default     = ""
}

variable "cloudflare_dns_ttl" {
  description = <<-EOT
    TTL in seconds for unproxied records. Kept LOW on purpose: DNS is the cutover
    and rollback lever for a migration, and the current estate's fatal flaw is
    hand-edited Namecheap records at TTL 1800 — half an hour of committed traffic
    with no way to shift it back.

    Ignored when cloudflare_proxied = true: a proxied record's TTL is managed by
    Cloudflare (the provider requires 1, meaning "automatic"), and cutover is
    instant because the edge address never changes — only the origin behind it.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.cloudflare_dns_ttl >= 60 && var.cloudflare_dns_ttl <= 1800
    error_message = "cloudflare_dns_ttl must be between 60 and 1800 seconds. Cloudflare's minimum for a non-enterprise zone is 60, and anything near 1800 defeats the point of having a cutover lever."
  }
}

variable "cloudflare_proxied" {
  description = "Proxy records through Cloudflare's edge (orange cloud) for TLS/WAF/CDN."
  type        = bool
  default     = true
}

variable "restrict_to_cloudflare" {
  description = "Restrict the instance security group's web ingress to Cloudflare's published edge ranges, so the origin cannot be reached directly by IP."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Reverse proxy binary
# ---------------------------------------------------------------------------

variable "caddy_version" {
  description = <<-EOT
    Caddy release to install, pinned.

    NOT fetched from `caddyserver.com/api/download`, which returns an unpinned
    binary with nothing to verify it against. This repository has already shipped
    one payload disguised as a font; an unverified binary downloaded onto the box
    at every boot is exactly the same class of exposure, and pinning plus a
    checksum costs nothing.
  EOT
  type        = string
  default     = "2.11.4"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.caddy_version))
    error_message = "caddy_version must be a bare semver like 2.11.4 (no leading v)."
  }
}

variable "caddy_sha512" {
  description = <<-EOT
    SHA-512 of the official `caddy_<version>_linux_<arch>.tar.gz` release asset,
    per architecture, as published in that release's `checksums.txt`.

    The bootstrap refuses to install a binary that does not match, so bumping
    caddy_version REQUIRES updating these — which is the point: the checksum is
    reviewed here, in the pull request, rather than trusted at 3am on the box.

    Defaults are the published checksums for 2.11.4:
      curl -fsSL https://github.com/caddyserver/caddy/releases/download/v2.11.4/caddy_2.11.4_checksums.txt
  EOT
  type        = map(string)
  default = {
    amd64 = "8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
    arm64 = "d5a7c423853c24a799765e0e8210d5c7c22a8f56ed37a3cae2fb9f58be138853c02b4efd6b59d576e6d8c7c0d30b9c1592deeaa6a536ff69bcca23b8c1ea709c"
  }

  validation {
    condition = alltrue([
      for k, v in var.caddy_sha512 : can(regex("^[0-9a-f]{128}$", v))
    ])
    error_message = "Each caddy_sha512 value must be a 128-character lowercase hex SHA-512."
  }

  validation {
    condition     = contains(keys(var.caddy_sha512), "amd64") && contains(keys(var.caddy_sha512), "arm64")
    error_message = "caddy_sha512 must contain both amd64 and arm64 keys (the architecture is chosen on the box from uname -m)."
  }
}

variable "allow_plaintext_origin" {
  description = <<-EOT
    Accept serving production hostnames over plaintext HTTP.

    Defaults to FALSE, and `guards.tf` fails the plan for a prod-bearing stack
    unless either Cloudflare or origin TLS is enabled. That refusal is deliberate:
    this platform carries children's personal data, and the alternative is
    cleartext credentials and story content across the public internet with
    0.0.0.0/0 ingress.

    Setting it true is only defensible BEFORE the DNS cutover, while the stack has
    no real traffic and is reachable only by its Elastic IP.
  EOT
  type        = bool
  default     = false
}

variable "enable_origin_tls" {
  description = <<-EOT
    Terminate HTTPS on the box with a Cloudflare Origin Certificate (Cloudflare
    SSL mode "Full (strict)"). When false the origin serves plain HTTP on :80 and
    TLS stops at Cloudflare's edge. Either way this replaces certbot: there are no
    Let's Encrypt renewals on the instance.
  EOT
  type        = bool
  default     = false
}

variable "origin_cert" {
  description = "Cloudflare Origin Certificate PEM. Required when enable_origin_tls = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "origin_key" {
  description = "Cloudflare Origin Certificate private key PEM. Required when enable_origin_tls = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "extra_web_ingress_cidrs" {
  description = "Additional IPv4 CIDRs allowed to reach :80/:443 (e.g. an office range during migration). Empty by default."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# CI / OIDC
# ---------------------------------------------------------------------------

variable "manage_github_oidc" {
  description = <<-EOT
    Create the account-global GitHub OIDC provider and the CI deploy role.

    Defaults to FALSE, deliberately. Creating a second provider for
    token.actions.githubusercontent.com in an account that already has one fails
    the apply, and which AWS account this is has not been settled. Failing safe
    here means "CI has no deploy role yet", an obvious and harmless gap, rather
    than "the first apply blows up".

    Confirm with `aws iam list-open-id-connect-providers`, then set it true. Note
    it also gates the CI deploy role, so both appear together.
  EOT
  type        = bool
  default     = false
}

variable "github_deploy_subjects" {
  description = <<-EOT
    Exact OIDC subject claims allowed to assume the CI deploy role, one per
    repo+ref. Enumerated rather than wildcarded so a fork or a feature branch
    cannot push images.

    Storytime is many repos, unlike FateRound's single repo, so the default
    covers the deploy branches of each app repo that produces an image.
  EOT
  type        = list(string)
  default = [
    "repo:Bolt-Silverfox/storytime_be:ref:refs/heads/develop-v1.2.0",
    "repo:Bolt-Silverfox/storytime_be:ref:refs/heads/develop-v1.3.0",
    "repo:Bolt-Silverfox/storytime_be:ref:refs/heads/main",
    "repo:Bolt-Silverfox/storytime-fe:ref:refs/heads/dev",
    "repo:Bolt-Silverfox/storytime-fe:ref:refs/heads/main",
    "repo:Bolt-Silverfox/storytime_superadmin:ref:refs/heads/dev",
    "repo:Bolt-Silverfox/storytime_superadmin:ref:refs/heads/main",
    "repo:Bolt-Silverfox/storytime-waitlist-be:ref:refs/heads/develop",
    "repo:Bolt-Silverfox/storytime-waitlist-be:ref:refs/heads/main",
    "repo:Bolt-Silverfox/storytime-waitlist-fe:ref:refs/heads/dev",
    "repo:Bolt-Silverfox/storytime-waitlist-fe:ref:refs/heads/main",
  ]
}
