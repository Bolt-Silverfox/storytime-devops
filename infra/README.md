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
| Containers per box | 1 | several — see [Topology](#topology) |
| Database | none (Supabase) | **one shared RDS serving all four environments at once** |
| Redis | none | **required** (BullMQ queues + cache + guest sessions) |
| Region | `us-east-1` | **`eu-west-1`** — a compliance decision, not a preference |
| State bucket | `fateround-tfstate` | `storytime-tfstate` (separate; no shared blast radius) |
| Reverse proxy | optional Caddy for origin TLS | **always** — several hostnames per box |
| CI subjects | one repo, two refs | five repos, enumerated refs |

No FateRound resource is imported, referenced or modified. That repo was read for
patterns only.

## Topology

**One instance per environment, several containers on it.** The alternative —
one instance per service per environment — is roughly 20 EC2 instances and 20
Elastic IPs for a platform whose entire traffic fits on two boxes today. The
reasoning, and what the choice costs, is written out at the top of
[`compute.tf`](compute.tf).

Consequences worth knowing before you apply anything:

- One box down takes the whole environment down. **Same as today**; this change
  does not make availability worse, and does not fix it either.
- Containers get per-service memory limits (`services[*].memory_mb`), which the
  current PM2 setup does not have.
- **`terraform apply` replaces the instance** whenever user-data changes. The
  normal deploy path is therefore *not* Terraform: CI calls
  `/usr/local/bin/redeploy.sh <service> <tag>` over SSM Run Command, which
  touches one container.
- PM2 cluster mode becomes `replicas = N` — N containers on consecutive host
  ports, round-robin behind the proxy. Prod runs `max(2, cpus-1)` workers today;
  pick the number explicitly, it is not derived.

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
├── variables.tf                 every input, with the reasoning in the descriptions
├── locals.tf                    prefix, container/route expansion, SSM param flattening
├── guards.tf                    plan-time fail-fast preconditions
├── network.tf                   VPC, public subnet, 2 private subnets, IGW
├── security.tf                  app SG (no :22) + data SG (app-only ingress)
├── ecr.tf                       shared per-service repositories
├── iam.tf                       instance role: ECR pull, own-environment SSM, SSM SM
├── compute.tf                   the instance, EIP, user-data  ← topology rationale
├── proxy.tf                     renders the Caddyfile in Terraform
├── ssm-config.tf                config_plain -> String, secret_keys -> SecureString
├── rds.tf                       read-only lookup of the shared DB; optional dedicated DB
├── redis.tf                     container | elasticache | external
├── github-oidc.tf               OIDC provider + CI deploy role
├── cloudflare.tf                DNS records, origin lockdown (off by default)
├── outputs.tf
├── templates/
│   ├── user-data.sh.tftpl       bootstrap + redeploy.sh + reverse proxy + redis
│   └── Caddyfile.tftpl          host-based routing, SSE-aware
├── terraform.shared.tfvars.example
├── terraform.dev.tfvars.example
└── terraform.prod.tfvars.example
```

## Workspaces

Five workspaces in one state bucket. `shared` is not a runtime environment: it
owns the resources that must exist exactly once per account (the ECR
repositories and the GitHub OIDC provider + CI role).

```
env:/shared/infra/terraform.tfstate    ECR repos, GitHub OIDC provider, CI role
env:/dev/infra/terraform.tfstate
env:/staging/infra/terraform.tfstate
env:/blue/infra/terraform.tfstate       the v1.3.0 parallel line
env:/prod/infra/terraform.tfstate
```

`guards.tf` fails the plan if `terraform.workspace` and `var.environment`
disagree, because in a workspace-per-environment layout every expensive mistake
is "right command, wrong workspace".

**Apply `shared` first.** Runtime workspaces read the ECR repositories through a
data source and their plans will fail until those repositories exist.

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

- **`guards.tf`** — workspace/environment mismatch, `shared` trying to create an
  instance, `create_database` without a password, `enable_origin_tls` without a
  certificate, `restrict_to_cloudflare` without a proxied record (which would
  make the origin unreachable), and secret names with no values: all fail at
  **plan** time.
- **RDS** carries `prevent_destroy` *and* `deletion_protection`, a mandatory final
  snapshot, and `ignore_changes` on `password` and `engine_version` so an
  out-of-band rotation or an AWS auto-minor-upgrade never shows up as a diff that
  an apply would "correct" against a live database.
- **ECR** is *not* `force_delete` (FateRound's is): a `destroy` there would take
  the images every environment is running, prod included.
- **IMDSv2 required**, hop limit 1 — IMDS is unreachable from inside a container,
  so a compromised app process cannot mint instance-role credentials.
- **Root EBS encrypted**; RDS and ElastiCache encrypted at rest, ElastiCache also
  in transit.
- **No port 22 anywhere.** Shell access is SSM Session Manager.
- Everything Cloudflare-related, the dedicated database, and origin TLS are
  **off by default**.

## Running it

Prerequisites: Terraform **>= 1.11**, AWS credentials for the target account,
Docker with buildx for image builds, and the state bucket bootstrapped above.

```bash
cd infra
terraform init

# Bootstrap workspace, once.
terraform workspace new shared
cp terraform.shared.tfvars.example terraform.shared.tfvars
terraform plan -var-file=terraform.shared.tfvars

# A runtime environment.
terraform workspace new dev
cp terraform.dev.tfvars.example terraform.dev.tfvars   # then fill in secret_values
terraform plan -var-file=terraform.dev.tfvars
```

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

`emerj-shared-db` is currently referenced **read-only** via
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

### Splitting the shared database

One RDS instance serves dev **and** staging **and** blue **and** prod
simultaneously. A dev migration, a bad seed, or a runaway query in staging is a
production incident. `create_database = true` per environment provisions a
dedicated instance, but the *cutover* — dump, restore, connection-string change,
verification, rollback plan — is a data-migration project, not a
`terraform apply`. It is deliberately off by default in every environment.

## Open decisions

Things that genuinely cannot be settled from here:

1. **Region / data residency.** Defaulted to **`eu-west-1`**, where everything
   already is. Storytime processes children's personal data and ships GDPR
   export features, so this is a compliance decision needing an explicit
   sign-off — not something to align with FateRound's `us-east-1`.
2. **Which AWS account.** FateRound is `772316781095`. Storytime's existing
   resources are named `emerj-*`, which suggests a different account. If it is
   the *same* account, the GitHub OIDC provider already exists and
   `manage_github_oidc` must stay `false` everywhere (creating a second provider
   for the same URL fails).
3. **The shared RDS split.** Prerequisite for real environment isolation, and the
   largest outstanding risk in the platform. Needs a migration plan.
4. **Redis per environment.** `container` (cheap, loses queued jobs on box
   replacement) vs `elasticache` (durable, costs money). Defaults: container for
   dev/blue, ElastiCache for staging/prod. Needs cost sign-off.
5. **Cloudflare or stay on Namecheap.** DNS is hand-edited at Namecheap today
   (TTL 1800, no CDN, no load balancer). Everything Cloudflare is off by default.
   Moving the zone also decides where TLS terminates.
6. **Moving waitlist production and the apex marketing site off the dev box.**
   They run on `52.18.195.224` today, alongside dev, staging and blue — so a dev
   deploy can take down the public marketing site. They are `enabled = false` in
   `terraform.prod.tfvars.example` pending a scheduled DNS cutover.
7. **Prod deploy authorisation.** The CI role is tag-scoped to the whole project,
   so one role can redeploy any environment including prod. If prod should need a
   separate role or a manual approval, split `gha_deploy_ssm` per environment.
8. **Dockerfiles do not exist yet.** No app repo has one. Nothing here can run
   until they do, and each needs the right Node base image — fe requires
   Node >= 24, superadmin pins 20, backend CI uses 22.
9. **The log viewer.** `logs.py` runs as a CGI behind nginx + fcgiwrap with basic
   auth. It has no service entry here: containerising a CGI, or replacing it with
   CloudWatch Logs, is an open question.
10. **The two waitlist API ports are unknown.** Both PM2 processes default to
    3000 and the real ports were never recorded. `enabled = false` until the
    capture output confirms them.
