# Storytime — AWS infrastructure (Terraform)

Terraform for the Storytime platform, modelled deliberately on the FateRound
stack (`chinazaaa/fateround`, `infra/`) so the two projects look and operate
alike: **one EC2 instance per environment, running the apps as Docker containers
pulled from ECR, config in SSM Parameter Store, IAM instance role + SSM Session
Manager instead of SSH keys, GitHub OIDC instead of long-lived AWS credentials,
S3 remote state with workspaces, no ALB / ASG / NAT gateway.**

> **Nothing here has been applied.** No `terraform apply` has been run, no AWS
> credentials were used, and no live server was touched. This is code for a human
> to review and run. See [Open decisions](#open-decisions) for what is still
> blocked.

## How this differs from FateRound, and why

FateRound is one Next.js app with Supabase behind it. Storytime is not, and the
differences are the substance of this stack rather than incidental:

| | FateRound | Storytime |
|---|---|---|
| Apps | 1 | 6 (backend API, web, superadmin, waitlist API, waitlist web, log viewer) |
| Environments | dev, prod | dev, staging, **blue**, prod |
| Containers per box | 1 | several — apps **plus Postgres and Redis** |
| Database | none (Supabase) | **Postgres container by default**, RDS behind a variable |
| Redis | none | **required** (BullMQ queues + cache + guest sessions) |
| Backups | n/a (Supabase) | **built here**: nightly `pg_dump` to S3 + DLM EBS snapshots |
| Region | `us-east-1` | **`eu-west-1`** — a compliance decision, not a preference |
| State bucket | `fateround-tfstate` | `storytime-tfstate` (separate; no shared blast radius) |
| Reverse proxy | optional Caddy for origin TLS | **always** — several hostnames per box |
| CI subjects | one repo, two refs | five repos, enumerated refs |

No FateRound resource is imported, referenced or modified. That repo was read for
patterns only.

## One box, and when to stop using one box

**Everything runs on ONE `t3.small`**: the applications, Postgres and Redis, all as
Docker containers behind an on-box Caddy reverse proxy, with one Elastic IP and
Cloudflare in front.

Storytime has **fewer than 100 monthly users**. An instance per environment came to
about **$225/mo** and was rejected as overbuilt, correctly. This design is meant to
scale *up* from a deliberately minimal base rather than down from a large one, so
every knob that would grow it is a variable.

### What that honestly means

- **dev, staging and prod share a host.** A bad deploy, a runaway migration, or an
  OOM in one can affect production. There is no per-environment blast radius.
- **It is not a recommendation to keep forever.** It is a cost trade-off that is
  right at this user count and wrong at some larger one.
- **No HA.** One box, one AZ. If it or its AZ has trouble, Storytime is down until
  it recovers or is rebuilt. Rebuilding is fast and documented
  ([`docs/migration.md`](../docs/migration.md)), but it is not automatic.
- Mitigations that *are* in place: per-container memory limits (the current PM2
  setup has none), and a plan-time memory budget so overcommitment fails in review
  rather than at 03:00.

### Split it out when one of these is true

Concrete triggers, not vibes:

| Trigger | Threshold |
|---|---|
| Sustained CPU | > 60% for a week, or steady-state credit balance falling on a `t3` |
| Memory headroom | `terraform output memory_budget` headroom under ~200 MiB with everything you need enabled |
| Prod traffic | sustained > ~5 req/s, or p95 latency degrading under normal load |
| An incident | any dev/staging action causes a production incident — split immediately, this is the real trigger |
| Compliance | an auditor asks for environment isolation, which a shared host cannot demonstrate |

Splitting is deliberately cheap: create a workspace, set
`environment = "prod"`, give it only the prod services, flip the Cloudflare
records. That is the whole procedure, and it is
[`docs/migration.md`](../docs/migration.md).

### Sizing and the memory budget

`t3.small` is 2 GiB, and Postgres and Redis live on the same box:

```
t3.small total                     2048 MiB
- host reserve (OS/docker/SSM)      -400
- postgres container                -512
- redis container                   -192
--------------------------------------------
available for application containers 944 MiB
```

Which is **two** small Node containers, not eighteen. `guards.tf` enforces this at
plan time and prints the arithmetic, so enabling a third service on a `t3.small`
fails in review:

```
Memory budget exceeded for t3.small (2048 MiB).
Committed: 2576 MiB = app containers 1472 + postgres 512 + redis 192 + host reserve 400
```

Raise `instance_type` to `t3.medium` (4 GiB) or `t3.large` (8 GiB) to enable more.
Every service must set `memory_mb`: an uncapped container on a shared box can OOM
the whole platform, so the plan rejects `memory_mb = 0`.

PM2 cluster mode becomes `replicas = N` — N containers on consecutive host ports,
round-robin behind the proxy.

## Cost

eu-west-1 list prices, on-demand:

| Item | Monthly |
|---|---|
| `t3.small` (2 vCPU, 2 GiB) — the default | **$16.64** |
| 30 GB gp3 root volume, encrypted | ~$2.70 |
| Public IPv4 (the Elastic IP, while attached) | **$3.65** |
| ECR / SSM / S3 backups / data transfer at this scale | ~$1 |
| **Default total** | **~$24/mo** |

What each variable costs if you change it:

| Change | Delta |
|---|---|
| `instance_type = "t3.medium"` (4 GiB) | +$16.65 → ~$41 |
| `instance_type = "t3.large"` (8 GiB) | +$49.94 → ~$74 |
| `use_managed_database = true`, `db.t4g.micro` | +$12.41 |
| `use_managed_database = true`, `db.t4g.small` | +$25.55 |
| `use_managed_database = true`, `db.t4g.medium` | +$50.37 |
| `redis_mode = "elasticache"`, `cache.t4g.micro` | +~$12 |
| One more environment on its own box | +~$24 |

**Public IPv4 is billed per address, ~$3.65/mo, attached or not.** That is small
until it is not: an audit of the sibling AWS account turned up **~$29/mo of
orphaned load balancer and unattached IPv4**. This stack allocates exactly one EIP
and nothing else with a public address, and there is no ALB and no NAT gateway
(which would add ~$16 and ~$32/mo respectively). Sweep for strays periodically:

```bash
aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId]' --output table
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table
```

## Migrating is a routine operation

The box is **disposable**: images in ECR, config in SSM, database dumps in S3, DNS
in Cloudflare. Losing the instance entirely costs the time to re-apply and restore.

Nothing a migration would have to hunt down is hardcoded — region, AZ, instance
type, hostnames and environment name are all variables, there are **no literal IP
addresses anywhere**, and the AMI comes from `data.aws_ami` with
`ignore_changes = [ami]` rather than a pinned id that would silently rot.

**Cloudflare is the cutover lever.** The legacy estate's fatal flaw is DNS
hand-edited at Namecheap with a 1800s TTL and no proxy layer, so there is no way to
shift traffic or roll back quickly. Here the record is in Terraform with
`cloudflare_dns_ttl` defaulting to 60s, and cutover is: **apply the new stack →
restore the latest dump → verify → flip the record → keep the old box until
confident.** Rollback is flipping the record back, which is why the old box must
not be destroyed in the same apply.

**The one known gap:** with `use_managed_database = false` the Postgres data
directory is a Docker volume on the instance's EBS volume, so it is the single piece
of state that lives only on the box. Recovery point is the nightly dump. That is the
accepted price of not paying for RDS at this scale, and it is why the next section
is not optional.

Full ordered procedure with commands and per-step checks:
[`docs/migration.md`](../docs/migration.md).

## Backups

**Read this before changing anything in `backups.tf`.**

This stack deliberately runs Postgres as a container rather than RDS to keep the
bill near $24/mo. That means **no RDS automated backups and no point-in-time
recovery**, so they are re-created here. Without them, self-hosting **children's
personal data under GDPR** on a single EBS volume would be reckless. The backups are
what make the cost trade defensible. Do not remove them as an optimisation.

Two layers, because they fail differently:

| | Layer 1 — logical dump | Layer 2 — EBS snapshot |
|---|---|---|
| What | `pg_dump --format=custom` to S3, nightly | DLM whole-volume snapshot, daily |
| Driven by | systemd timer on the box (`storytime-pg-backup.timer`) | AWS, needs nothing from the box |
| Survives | losing the instance, the volume, or the AZ | a corrupted/truncated dump, a compromised backup script |
| Vulnerable to | a dump that succeeds but is garbage | losing the region |
| Retention | `backup_retention_days` (30) + 7 days of noncurrent versions | `ebs_snapshot_retain_count` (7) |

`--format=custom` rather than plain SQL so `pg_restore` can do selective and
parallel restores, and because it compresses.

> **Neither layer survives losing the region.** Both the dump bucket and the EBS
> snapshots live in `var.aws_region`, and this configuration sets up **no
> cross-region replication**. An earlier version of this table claimed layer 1
> covered regional loss; it does not, and overclaiming backup coverage is exactly
> the false confidence these backups exist to avoid.
>
> If you want cross-region durability, add an `aws_s3_bucket_replication_configuration`
> to a bucket in a second region (plus a replication IAM role, and versioning on
> both — versioning is already enabled here). That is deliberately **not** done:
> it costs cross-region transfer plus a second bucket's storage, and moving
> children's personal data into another region is the same data-residency decision
> discussed under [Region](#region-and-data-residency). It needs a human call, not
> a default.

The bucket is created by Terraform: **versioned, SSE-encrypted, public-access
blocked, TLS-only** (a bucket policy denying `aws:SecureTransport=false`), with a
lifecycle rule that expires dumps and aborts incomplete multipart uploads. It is
**not** `force_destroy`, so `terraform destroy` cannot take the backup history with
it.

The instance role can **write only under this stack's own prefix** in this one
bucket, and is deliberately **not granted `s3:DeleteObject`** — expiry is the
lifecycle rule's job, so a compromised box cannot destroy the history.

### The dump fails loudly

`pg-backup.sh` refuses to call a backup successful unless every one of these holds:

1. `pg_dump` exits zero;
2. the local dump is at least 1 KiB (a custom-format header alone is a few hundred
   bytes, so anything smaller is not a database);
3. `pg_restore --list` can parse it — which catches a truncated or corrupt archive
   that `pg_dump` returned 0 for;
4. the upload succeeds, **and** `head-object` reports a size equal to the local
   dump, catching a truncated upload.

Only then does it write the heartbeat.

### How a failure surfaces

**A stale heartbeat.** `_status/last-success.json` is overwritten only after all
four checks pass, so failure looks like a timestamp that stopped moving — readable
from anywhere, without shell access. That matters: if the box is gone you cannot
read its journal.

```bash
aws s3 cp "s3://$(terraform output -raw backup_bucket)/_status/last-success.json" - | cat
```

`last_success_utc` older than ~24 hours means the backups are broken. On the box,
`systemctl status storytime-pg-backup.timer` and
`journalctl -u storytime-pg-backup.service` have the detail, and an `OnFailure` unit
logs at `crit`.

**Wiring that heartbeat to something that pages a human is not done** — it is a
follow-up, and until it exists someone has to look.

### Restore

Documented and scripted, because a backup nobody has restored is not a backup.

Run this **on the box** (`aws ssm start-session --target <instance_id>`):

```bash
set -euo pipefail

STACK=<name_prefix>-<environment>          # e.g. storytime-all
BUCKET=<backup bucket>                     # terraform output -raw backup_bucket

# The dump is plaintext children's personal data while it is on disk. Register
# cleanup BEFORE creating it, so an interruption cannot leave a copy behind, and
# make the two deletions independent — chaining them with && means a failure in
# the first skips the second.
cleanup() {
  docker exec postgres rm -f /tmp/restore.dump >/dev/null 2>&1 || true
  if [ -f /var/tmp/restore.dump ]; then shred -u /var/tmp/restore.dump || rm -f /var/tmp/restore.dump; fi
}
trap cleanup EXIT INT TERM HUP

# Use the CONFIGURED identity, not a guess: db_name/db_username are variables, so
# hardcoding `storytime` restores into the wrong database (or fails) on any stack
# that changed them.
DB_USER=$(aws ssm get-parameter --name "/$STACK/_db/USERNAME" --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$STACK/_db/NAME"     --query 'Parameter.Value' --output text)

# Newest dump. Keys are date-ordered, so lexicographic == chronological.
KEY=$(aws s3 ls "s3://$BUCKET/postgres/$STACK/" --recursive | awk '{print $4}' \
        | grep '\.dump$' | sort | tail -1)
[ -n "$KEY" ] || { echo "no dump found" >&2; exit 1; }
aws s3 cp "s3://$BUCKET/$KEY" /var/tmp/restore.dump

# --clean --if-exists makes this repeatable; without them a second attempt fails
# on objects that already exist.
docker cp /var/tmp/restore.dump postgres:/tmp/restore.dump
docker exec postgres pg_restore \
  --username="$DB_USER" --dbname="$DB_NAME" \
  --clean --if-exists --no-owner --no-privileges --jobs 2 \
  /tmp/restore.dump
```

Errors about roles or extensions are normal with `--no-owner --no-privileges`.
Errors about *tables* are not.

Full procedure with verification steps: [`docs/migration.md`](../docs/migration.md)
step 5.

### Restore verification

`enable_restore_verification` (on by default) installs a weekly job that pulls the
newest dump, restores it into a **throwaway** Postgres container on no published
port, asserts the table count is at least `restore_verify_min_tables`, and destroys
the container. It never touches the live database. The result is recorded at
`_status/last-restore-verify.json`, so "when was a restore last actually exercised"
is answerable without shell access.

> **The restore has NOT been exercised against real data yet.** Nothing in this
> repository has been applied. Drill it — [`docs/migration.md`](../docs/migration.md)
> step 2 — before trusting it. Until a human has restored a real dump and looked at
> the rows, these are backups on paper.

### What replaces what

| Today (hand-built) | Here |
|---|---|
| PM2 + `ecosystem.config.js` in each app repo | Docker containers + `var.services` |
| nvm juggling Node 20 / 22 / 24 on one box | each service's own image, its own base |
| nginx vhosts edited on disk, in no repo | `templates/Caddyfile.tftpl`, rendered by Terraform and visible in `plan` |
| certbot + a renewal timer/cron | Cloudflare edge TLS, or a Cloudflare Origin Certificate from SSM |
| `.env` files on disk | SSM Parameter Store, read at boot into a tmpfs env-file that is deleted immediately |
| SSH keys | SSM Session Manager (**no port 22 rule exists in `security.tf`**) |
| no `pm2 startup` unit — a reboot leaves everything down | `--restart always` + enabled `docker.service` + a `storytime-reconcile` unit |

The app repos are **not touched**. Their `ecosystem.config.js` files stay where
they are; they simply stop being the thing that runs in the new model.

## Layout

```
infra/
├── versions.tf                  provider + required_version pins, S3 backend
├── providers.tf                 aws provider, default_tags
├── variables.tf                 every input, with the reasoning in its description
├── locals.tf                    prefix, container/route expansion, memory budget
├── guards.tf                    plan-time fail-fast preconditions  <- read this
├── network.tf                   VPC, public subnet, 2 private subnets, IGW
├── security.tf                  app SG (no :22) + data SG (app-only ingress)
├── ecr.tf                       per-service repositories, shared across stacks
├── iam.tf                       instance role: ECR pull, own-prefix SSM, backup write
├── compute.tf                   the instance, EIP, user-data
├── proxy.tf                     renders the Caddyfile in Terraform
├── ssm-config.tf                config_plain -> String, secret_keys -> SecureString
├── database.tf                  container Postgres | RDS, behind one variable
├── backups.tf                   S3 dump bucket + DLM snapshots  <- load-bearing
├── redis.tf                     container | elasticache | external
├── github-oidc.tf               OIDC provider + CI deploy role
├── cloudflare.tf                DNS records (the cutover lever), origin lockdown
├── outputs.tf                   incl. memory_budget + backup health checks
├── templates/
│   ├── user-data.sh.tftpl       bootstrap: docker, postgres, redis, containers,
│   │                            caddy (pinned + SHA-512 verified), backup timers
│   └── Caddyfile.tftpl          host-based routing, SSE-aware
├── terraform.all.tfvars.example      <- START HERE (the single box)
├── terraform.shared.tfvars.example   optional account-global-only stack
├── terraform.dev.tfvars.example      } for when an environment is
├── terraform.prod.tfvars.example     } split onto its own box
├── .terraform.lock.hcl          committed on purpose (pins provider versions)
└── .gitignore
```

## Workspaces

**`all` is the default and, initially, the only one.** The rest exist so an
environment can be peeled off later without rewriting anything.

```
env:/all/infra/terraform.tfstate        <- the single box: every environment on it
env:/shared/infra/terraform.tfstate     optional: account-global resources only
env:/dev/infra/terraform.tfstate        }
env:/staging/infra/terraform.tfstate    } created only when an environment is
env:/blue/infra/terraform.tfstate       } split onto its own box
env:/prod/infra/terraform.tfstate       }
```

`guards.tf` fails the plan if `terraform.workspace` and `var.environment`
disagree, because in a workspace-per-environment layout every expensive mistake
is "right command, wrong workspace".

With `all`, that stack owns the ECR repositories itself (`manage_shared_ecr = true`),
so there is no two-step bootstrap. Only if you later split environments does one
stack need to own the repositories while the others read them through a data
source — and then that one must be applied first.

## Remote state

State lives in **`s3://storytime-tfstate`** (`eu-west-1`), configured in
`versions.tf`. Locking uses S3 conditional writes (`use_lockfile`), so there is
no DynamoDB lock table — this needs Terraform **>= 1.11**.

The bucket is **deliberately not managed by this configuration** (a config cannot
safely own the bucket that stores its own state). Bootstrap it out of band, once:

```bash
BUCKET=storytime-tfstate       # must be globally unique; if taken, append the account id
REGION=eu-west-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Deny any non-TLS request to the bucket and its objects.
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
JSON
)"
```

Note the `LocationConstraint`: unlike FateRound's `us-east-1` bucket, an
`eu-west-1` bucket requires it.

If you change the bucket name, change it in `versions.tf` too — backend config
cannot use variables.

## Configuration convention (SSM)

Every parameter lives at:

```
/<name_prefix>-<environment>/<service>/<KEY>
```

e.g. `/storytime-dev/api/DATABASE_URL`. The instance role can read **only its own
environment's subtree**, so a dev box cannot read prod config — something the
current `.env`-on-disk model cannot enforce.

Three variables, and the split is the point:

| Variable | Sensitive? | Committed? | Becomes |
|---|---|---|---|
| `config_plain` | no | yes | SSM `String` |
| `secret_keys` | no — **names only** | **yes** | the set of `SecureString` names |
| `secret_values` | yes | **never** | the `SecureString` values |

Keeping the *names* in version control means the shape of an environment's
configuration is reviewable and diffable in a pull request — you can see that a
key was added or removed — while no value ever enters git. It is also exactly the
shape `capture/capture-host.sh` emits, so its output pastes straight in.

Supply `secret_values` from a gitignored `terraform.<env>.tfvars`, or from
`TF_VAR_secret_values`. `guards.tf` fails the plan if a name in `secret_keys` has
no value, because an empty value would blank a live parameter.

**Multi-line secrets** (PEM keys, Google service-account JSON) must be stored
**base64-encoded** and decoded by the app: `docker --env-file` has no way to
represent a newline in a value, and the bootstrap skips such a parameter with a
warning rather than writing a corrupt env-file.

### How the instance reads it

`user-data.sh.tftpl` writes `/usr/local/bin/redeploy.sh`, which on every
invocation calls `ssm get-parameters-by-path --recursive --with-decryption` for
`/<prefix>/<service>/`, materialises a `docker --env-file` under **`/run`
(tmpfs, mode 600, in a 0700 directory)**, passes it to `docker run`, and deletes
it — with an `EXIT` trap so decrypted secrets do not survive any exit path.
Nothing persistent is written. Rotating a secret is "update the parameter,
re-run redeploy" — no Terraform, no file edit on the box.

## Safety rails

All of these fail at **plan** time, before anything is created:

- **Workspace/environment mismatch** — in a workspace-per-stack layout every
  expensive mistake is "right command, wrong workspace".
- **Memory budget** — committed container memory versus the instance's RAM, with the
  arithmetic in the error message. Also rejects `memory_mb = 0`: an uncapped
  container on a shared box can OOM the entire platform.
- **Duplicate hostnames** across services — Caddy rejects two site blocks for one
  address, which would kill the bootstrap before any container started.
- **`config_plain` PORT disagreeing with `container_port`** — the proxy routes to
  `container_port`, so a mismatch means an app listening where nothing is looking.
- **Plaintext production** — a prod-bearing stack with neither Cloudflare nor origin
  TLS is refused, unless `allow_plaintext_origin` says so explicitly. Children's
  personal data does not go over the public internet in cleartext by omission.
- **A secret name with no value** — an empty value would blank a live SSM parameter.
- **`db_password` missing** — required for both database backends.
- **`restrict_to_cloudflare` without a proxied record** — that combination makes the
  origin unreachable.

At apply/runtime:

- **RDS** carries `prevent_destroy` *and* `deletion_protection`, a mandatory final
  snapshot, and `ignore_changes` on `password` and `engine_version` so an
  out-of-band rotation or an AWS auto-minor upgrade never becomes a diff an apply
  would "correct" against a live database.
- **The backup bucket is not `force_destroy`** — `terraform destroy` cannot take the
  backup history with it. The instance role has **no `s3:DeleteObject`**.
- **ECR is not `force_delete`** (FateRound's is) — a destroy there would take the
  images every environment is running.
- **The Caddy binary is pinned and SHA-512 verified** against the digest committed in
  `var.caddy_sha512`, not pulled unverified from `caddyserver.com/api/download`. A
  mismatch aborts the bootstrap. This repository has already shipped one payload
  disguised as a font; an unverified root-installed binary is the same exposure.
- **IMDSv2 required**, hop limit 1 — IMDS is unreachable from inside a container, so
  a compromised app process cannot mint instance-role credentials.
- **Root EBS encrypted**; RDS and ElastiCache encrypted at rest, ElastiCache also in
  transit; the backup bucket SSE-encrypted and TLS-only.
- **No port 22 anywhere.** Shell access is SSM Session Manager.
- **`Postgres is never recreated in place`** — the bootstrap starts an existing
  container rather than replacing it, because recreating with a different image tag
  against an initialised data directory is how a major-version mismatch corrupts a
  database.
- Cloudflare, the managed database, and origin TLS are all **off by default**.

## Running it

Prerequisites: Terraform **>= 1.11**, AWS credentials for the target account,
Docker with buildx for image builds, and the state bucket bootstrapped above.

```bash
cd infra
terraform init

terraform workspace new all
cp terraform.all.tfvars.example terraform.all.tfvars
# then: set the real hostnames, choose a TLS path, fill in secret_values
export TF_VAR_db_password='...'          # required; keep it out of the file
terraform plan -var-file=terraform.all.tfvars
```

**The shipped example fails the plan on purpose.** `environment = "all"` serves
production hostnames, and neither `cloudflare_enabled` nor `enable_origin_tls` is
set, so `guards.tf` refuses rather than quietly serving children's data over
plaintext HTTP. Pick a TLS path — or set `allow_plaintext_origin = true`, which is
only defensible pre-cutover with no real traffic.

### Dry-running safely

`plan` never mutates anything, so read the plan first, every time:

```bash
terraform plan -var-file=terraform.dev.tfvars -out=dev.tfplan
terraform show dev.tfplan            # review the whole thing
terraform apply dev.tfplan           # apply exactly what you read
```

Saving the plan and applying *that file* removes the window where the world
changes between plan and apply.

Sanity checks that need no credentials at all:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

Note that `--check --diff` is Ansible; the Terraform equivalent is
`plan` / `show`. `terraform plan -refresh=false` is a useful faster read once you
trust the state.

## Deploying an image

```bash
ACCOUNT_ID=<account-id>
REGION=eu-west-1
REPO=$(terraform output -json ecr_repository_urls | jq -r '.api')
TAG=$(git rev-parse --short HEAD)     # immutable tag, not `latest`

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

docker buildx build --platform linux/amd64 -t "$REPO:$TAG" --push .
```

Then either:

- **In place (normal path):** SSM Run Command →
  `/usr/local/bin/redeploy.sh api <TAG>`. One container, no Terraform.
- **Through Terraform:** set `services.api.image_tag = "<TAG>"` and apply. This
  changes user-data and therefore **replaces the instance**, taking every other
  container on it with it. Use it for shape changes, not routine deploys.

Re-applying with an unchanged `image_tag` is a no-op, and a plain reboot does not
re-run user-data on Amazon Linux 2023 — which is why `latest` is a bad tag here.

## Adopting the existing RDS

`the legacy shared RDS instance` is currently referenced **read-only** via
`data.aws_db_instance.shared`, purely so its endpoint appears in outputs.
Terraform does not manage it.

Importing it is a separate, deliberate exercise and must not be done casually —
an import followed by an apply with drifted attributes is how live databases get
replaced. When you do it:

1. Write an `aws_db_instance` resource whose attributes you have **read off the
   live instance first** (`aws rds describe-db-instances`), with
   `lifecycle { prevent_destroy = true }` from the very first commit.
2. Use a config-driven `import` block, so the import is visible in a plan and
   reviewable, rather than `terraform import` mutating state directly.
3. `terraform plan` and confirm the output says **no changes**. If it proposes
   *any* modification, and especially anything marked "must be replaced", stop
   and fix the resource definition — do not apply.

### Migrating off the legacy shared database

One legacy RDS instance serves dev **and** staging **and** blue **and** prod
simultaneously, and it is publicly resolvable. A dev migration, a bad seed, or a
runaway query in staging is a production incident.

The target here is not "split it four ways" — it is **migrate off it entirely** onto
this stack's own Postgres (container by default, RDS if `use_managed_database`
becomes true). That is [`docs/migration.md`](../docs/migration.md) step 5: dump the
legacy instance, restore into the new one, verify, cut over, keep the old one until
confident.

Until that happens the legacy instance is only ever *read* by Terraform, via
`data.aws_db_instance.shared`, so its endpoint appears in outputs during the
migration.

## Region and data residency

Defaulted to **`eu-west-1`**, where every existing resource already is.

Storytime processes **children's personal data** and ships **GDPR data-export
features**, so region is a **data-residency and compliance decision**, not a latency
preference — FateRound's own README frames region choice exactly that way. Moving it
to `us-east-1` for consistency with FateRound would move children's personal data to
another jurisdiction. **Do not do that without an explicit, recorded decision.**

It is `var.aws_region`, so changing it is one line plus a migration
([`docs/migration.md`](../docs/migration.md)) — not a rewrite.

## Open decisions

Things that genuinely cannot be settled from here:

1. **Region sign-off** — see the section immediately above. `eu-west-1` is the
   default; a change is a GDPR decision.
2. **Which AWS account.** FateRound is `772316781095`. Storytime's existing
   resources are named `emerj-*`, which suggests a different account. If it is
   the *same* account, the GitHub OIDC provider already exists and
   `manage_github_oidc` must stay `false` everywhere (creating a second provider
   for the same URL fails).
3. **Migrating off the legacy shared database.** The largest outstanding risk in
   the platform. Procedure is written; scheduling it and accepting the downtime
   window is a human call.
4. **Whether the ~24h backup RPO is acceptable.** That is what a container Postgres
   with nightly dumps gives you. `use_managed_database = true` buys PITR for
   +$12.41/mo. This is a data-loss-tolerance decision about children's data.
5. **Drilling the restore.** Nothing here has been applied, so no dump has ever been
   restored. Until a human does it once, the backups are unproven.
6. **Cloudflare or stay on Namecheap.** DNS is hand-edited at Namecheap today
   (TTL 1800, no CDN, no load balancer). Everything Cloudflare is off by default.
   Moving the zone also decides where TLS terminates.
7. **Moving waitlist production and the apex marketing site off the shared box.**
   They run on `host-a` today, alongside dev, staging and blue — so a dev
   deploy can take down the public marketing site. They are `enabled = false` in
   `terraform.prod.tfvars.example` pending a scheduled DNS cutover.
8. **Prod deploy authorisation.** The CI role is tag-scoped to the whole project,
   so one role can redeploy any environment including prod. If prod should need a
   separate role or a manual approval, split `gha_deploy_ssm` per environment.
9. **Dockerfiles do not exist yet.** No app repo has one. Nothing here can run
   until they do, and each needs the right Node base image — fe requires
   Node >= 24, superadmin pins 20, backend CI uses 22.
10. **The log viewer.** `logs.py` runs as a CGI behind nginx + fcgiwrap with basic
   auth. It has no service entry here: containerising a CGI, or replacing it with
   CloudWatch Logs, is an open question.
11. **The two waitlist API ports are unknown.** Both PM2 processes default to
    3000 and the real ports were never recorded. `enabled = false` until the
    capture output confirms them.

## Follow-ups outside this repository

Not fixed here, listed so they are not forgotten:

1. **`storytime_be/.github/workflows/dev-deploy.yml` hardcodes the legacy host's
   `IP:22` and the legacy RDS hostname** across five `step-security/harden-runner`
   `allowed-endpoints` blocks under `egress-policy: block`. Any migration silently
   breaks dev deploys until that file is edited, and the failure looks like a
   network problem rather than a configuration one. This is exactly the hidden
   coupling this work exists to remove.
2. **No Dockerfile in any app repo.** Nothing here can run until they exist, each on
   the right Node base (fe >= 24, superadmin 20, backend 22).
3. **No CI workflow builds or pushes images to ECR.** The OIDC role and its ECR
   permissions are here; the workflow that uses them is not.
4. **Nothing pages a human when the backup heartbeat goes stale.** The signal exists
   and is readable from anywhere; wiring it to an alert does not.
5. **This repository is public**, and its git history — including this branch's
   earlier commits — contains the legacy host IPs and RDS endpoint. They have been
   removed from the working tree. Whether to make the repository private or rewrite
   history is a human decision.
