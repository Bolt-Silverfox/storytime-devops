# Storytime DevOps

Infrastructure-as-Code for the Storytime platform.

Storytime is seven independent repositories, each with its own deploy pipeline.
This repository owns the **infrastructure they run on** — it does not own the
applications, and it does not touch their repos.

> ### Status: foundation. Nothing here has been applied.
> No `terraform apply` has been run, no AWS credentials were used, and no live
> server has been touched by anything in this repository. Everything is written
> to be read and run by a human.

## What is here

```
capture/     read-only inventory of the two existing hand-built hosts
infra/       Terraform: ONE EC2 box, Docker + ECR + SSM, ~$24/mo
docs/        current state, and the migration runbook
```

| Path | Purpose |
|---|---|
| [`capture/`](capture/) | A **read-only** script that dumps the undocumented live state of a host into a timestamped directory. **Names only, never secret values.** Start here. |
| [`infra/`](infra/) | The Terraform stack, modelled on the FateRound pattern: **one shared EC2 box initially** (dev + staging + prod on it, ~$24/mo), split into per-environment boxes later. Containers from ECR, config in SSM, no SSH. |
| [`docs/current-state.md`](docs/current-state.md) | The verified inventory of the two live boxes: hosts, ports, the shared database, the Node version conflict, and what is in no repo at all. |
| [`docs/migration.md`](docs/migration.md) | The ordered runbook for moving onto (or between) stacks — with commands, per-step checks, and the rollback. |

## Order of work: capture → codify → provision

This order is not a suggestion. Each step depends on the previous one.

### 1. Capture

Nobody knows what the two live boxes actually run. The nginx vhosts for `api`,
`dev.api`, `staging.api`, `admin`, `dev.admin` and the apex marketing site exist
**only on disk and are in no repository**. Neither are the real waitlist API
ports, the certificate renewal mechanism, the Redis settings, or the actual set
of environment variables each app needs.

```bash
cd capture
./capture-host.sh --list-commands   # prove to yourself it only reads
./capture-host.sh                   # -> captures/<host>-<timestamp>/
```

See [`capture/README.md`](capture/README.md) — including how to get it onto a
host over SSH or SSM Session Manager, and the secret-redaction rules.

**Captures are gitignored by default.** Committing one is a deliberate act after
reviewing it.

### 2. Codify

Turn the capture into `infra/terraform.<env>.tfvars`. Note that the captured
environment variables split two ways, and the split matters:

- **Secret** names go in `secret_keys` (committed — names only) with their values
  in `secret_values` (gitignored, never committed). These become SSM
  `SecureString` parameters.
- **Non-secret** settings go in `config_plain` as name *and* value, both
  committed. These become SSM `String` parameters.

The capture reports every variable as `KEY=<set>` / `KEY=<empty>` without
distinguishing the two, because it cannot know which is which — deciding that is
the codifying work.

Then: nginx vhosts become `services[*].hostnames` plus the SSE / body-size /
timeout flags, `ss -tlnp` resolves the unknown ports, and the BullMQ queue depths
decide whether that environment can live with a Redis container.

Dockerfiles are also part of this step, and **none exist yet** in any app repo.

### 3. Provision

Bootstrap the state bucket out of band, then the `all` workspace — reading every plan
before applying it. See [`infra/README.md`](infra/README.md).

```bash
cd infra && terraform init
terraform workspace new all
cp terraform.all.tfvars.example terraform.all.tfvars
export TF_VAR_db_password='...'
terraform plan -var-file=terraform.all.tfvars
```

The shipped example **fails the plan on purpose** until you choose a TLS path — a
prod-bearing stack will not quietly serve children's data over plaintext HTTP.

## Target architecture, in one paragraph

**One** `t3.small` EC2 instance (Amazon Linux 2023) in `eu-west-1`, running every
service — plus **Postgres and Redis** — as **Docker containers** pulled from **ECR**,
with a stable Elastic IP, an on-box Caddy reverse proxy doing host-based routing, and
**Cloudflare** in front. All configuration lives in **SSM Parameter Store**, read at
boot into a tmpfs env-file that is deleted immediately — **no `.env` files on disk**.
Shell access is **SSM Session Manager**; there are **no SSH keys and no port 22
rule**. CI authenticates with **GitHub OIDC**, so no long-lived AWS credentials sit
in a GitHub secret. State is in **S3 with workspaces**. No ALB, no Auto Scaling
Group, no NAT gateway. **~$24/month.**

Storytime has fewer than 100 monthly users; one instance per environment came to
~$225/mo and was rejected as overbuilt. The cost of one shared box — dev, staging and
prod on one host, no HA — is
[stated plainly](infra/README.md#one-box-and-when-to-stop-using-one-box), along with
the concrete triggers for splitting it up. Every knob that would grow it is a
variable.

**Because there is no managed database, backups are load-bearing and mandatory:**
nightly `pg_dump --format=custom` to a versioned, encrypted, TLS-only S3 bucket, plus
independent DLM EBS snapshots, plus a weekly job that restores the newest dump into a
throwaway container and counts the tables. Failure surfaces as a stale S3 heartbeat,
readable without touching the box. This is children's personal data under GDPR;
[do not remove the backups](infra/README.md#backups).

**The box is disposable and migrating is routine.** Images in ECR, config in SSM,
dumps in S3, DNS in Cloudflare — losing the instance costs the time to re-apply and
restore. Nothing a migration would have to hunt down is hardcoded: no literal IPs, no
pinned AMI id, region and hostnames are variables, and Cloudflare with a 60s TTL is
the cutover *and rollback* lever. See [`docs/migration.md`](docs/migration.md).

This deliberately mirrors the FateRound stack (`chinazaaa/fateround`, `infra/`) so the
two projects operate alike. Where Storytime genuinely differs — six services instead
of one, a database, required Redis, `eu-west-1` for data residency — those are
documented as differences rather than papered over. No FateRound resource is imported
or modified.

## Still hand-built, still not codified

- **Everything currently running.** Both boxes remain hand-built until a
  migration is planned and executed; this repository does not change them.
- **Dockerfiles.** No app repo has one. Nothing in `infra/` can run until they
  exist, and each needs the right Node base (fe >= 24, superadmin 20, backend 22).
- **The legacy shared RDS.** Referenced read-only. Migrating off it is
  [`docs/migration.md`](docs/migration.md) step 5, and is not automatic.
- **The restore has never been exercised.** Nothing here has been applied, so no dump
  has ever been restored. Until a human drills it, the backups are unproven.
- **DNS.** Hand-edited at Namecheap, TTL 1800. All Cloudflare support is off by
  default.
- **The log viewer** (`logs.py`, a CGI behind nginx + fcgiwrap). No service entry
  yet.
- **CI workflows** to build and push images. Not written.
- **Observability.** No metrics, no log shipping, and **nothing pages a human when
  the backup heartbeat goes stale** — the signal exists, the alert does not.

The full list, with the decisions each one is waiting on, is in
[`infra/README.md` → Open decisions](infra/README.md#open-decisions).

## Conventions

- Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Branch prefixes: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`.
- Default branch: `main`.
- **Secrets never enter a tracked file.** Not in a committed tfvars, not in a
  capture, not in a vault file with a placeholder key. `secret_keys` (names only)
  *is* committed; `secret_values` is not.
  The two supported ways to supply values are a **gitignored**
  `infra/terraform.<env>.tfvars` and `TF_VAR_` environment variables — both are
  fine, and `guards.tf` rejects the plan if neither provides a value.
