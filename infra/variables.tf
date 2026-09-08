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
    Which environment this workspace represents.

    `shared` is not a runtime environment: it is the bootstrap workspace that
    owns the account-global resources (ECR repositories, the GitHub OIDC
    provider). Apply `shared` first, once, then the runtime environments.
  EOT
  type        = string

  validation {
    condition     = contains(["shared", "dev", "staging", "blue", "prod"], var.environment)
    error_message = "environment must be one of: shared, dev, staging, blue, prod."
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
    EC2 instance type for this environment's application host.

    Sizing note: this box runs SEVERAL containers (see var.services), not one.
    The shared multi-env box today runs ~10 PM2 processes, so a t3.small is not
    a realistic starting point for dev/staging/blue.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB). Must hold several container images plus logs; `docker image prune -af` runs on each redeploy."
  type        = number
  default     = 40

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB (multiple container images plus logs)."
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

variable "shared_db_identifier" {
  description = <<-EOT
    Identifier of the EXISTING shared RDS instance (today: emerj-shared-db in
    eu-west-1, serving dev AND staging AND blue AND prod at the same time).

    When set, a READ-ONLY data source looks it up so its endpoint can be
    surfaced in outputs and referenced while environments still share it.
    Terraform never modifies it through this variable. Leave "" to skip.
  EOT
  type        = string
  default     = ""
}

variable "create_database" {
  description = <<-EOT
    Create a DEDICATED RDS Postgres instance for this environment.

    DEFAULTS TO FALSE. Splitting the single shared database is a prerequisite
    for real environment isolation, but it is a data-migration project, not a
    `terraform apply`. Turn this on per environment only when the cutover for
    that environment is planned. The resource carries prevent_destroy and
    deletion_protection.
  EOT
  type        = bool
  default     = false
}

variable "db_engine_version" {
  description = "Postgres engine version for a dedicated instance. Must match or exceed what the shared instance runs; confirm with the capture output before setting."
  type        = string
  default     = "16.4"
}

variable "db_instance_class" {
  description = "Instance class for a dedicated RDS instance."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage (GiB) for a dedicated RDS instance."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB) for a dedicated RDS instance. 0 disables autoscaling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database name for a dedicated RDS instance."
  type        = string
  default     = "storytime"
}

variable "db_username" {
  description = "Master username for a dedicated RDS instance."
  type        = string
  default     = "storytime"
}

variable "db_password" {
  description = "Master password for a dedicated RDS instance. Required when create_database = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "db_backup_retention_days" {
  description = "Automated backup retention for a dedicated RDS instance. Never 0 — 0 disables backups AND point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "db_backup_retention_days must be >= 1; 0 disables automated backups and PITR."
  }
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
  description = "Engine version when redis_mode = \"elasticache\"."
  type        = string
  default     = "7.1"
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
  description = "Create the account-global GitHub OIDC provider and the CI deploy role. Set true only in the `shared` workspace; if the AWS account already has a provider for token.actions.githubusercontent.com, leave this false and reuse it."
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
