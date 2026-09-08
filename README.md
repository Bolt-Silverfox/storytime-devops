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
infra/       Terraform: EC2 + Docker + ECR + SSM, one instance per environment
docs/        what exists today, written down for the first time
```

| Path | Purpose |
|---|---|
| [`capture/`](capture/) | A **read-only** script that dumps the undocumented live state of a host into a timestamped directory. **Names only, never secret values.** Start here. |
| [`infra/`](infra/) | The Terraform stack, modelled on the FateRound pattern: one EC2 per environment running containers from ECR, config in SSM, no SSH. |
| [`docs/current-state.md`](docs/current-state.md) | The verified inventory of the two live boxes: hosts, ports, the shared database, the Node version conflict, and what is in no repo at all. |

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

Turn the capture into `infra/terraform.<env>.tfvars`: environment variable names
become `secret_keys`, nginx vhosts become `services[*].hostnames` plus the SSE /
body-size / timeout flags, `ss -tlnp` resolves the unknown ports, and the BullMQ
queue depths decide whether that environment can live with a Redis container.

Dockerfiles are also part of this step, and **none exist yet** in any app repo.

### 3. Provision

Bootstrap the state bucket, apply the `shared` workspace, then one environment at
a time — reading every plan before applying it. See
[`infra/README.md`](infra/README.md).

## Target architecture, in one paragraph

One EC2 instance per environment (Amazon Linux 2023), running each service as a
**Docker container** pulled from a shared **ECR** repository, with a stable
Elastic IP and an on-box Caddy reverse proxy doing host-based routing. All
configuration lives in **SSM Parameter Store** and is read at boot into a tmpfs
env-file that is deleted immediately — **no `.env` files on disk**. Shell access
is **SSM Session Manager**; there are **no SSH keys and no port 22 rule**. CI
authenticates with **GitHub OIDC**, so no long-lived AWS credentials exist in any
GitHub secret. State is in **S3 with workspaces** (`shared`, `dev`, `staging`,
`blue`, `prod`). No ALB, no Auto Scaling Group, no NAT gateway.

This deliberately mirrors the FateRound stack (`chinazaaa/fateround`, `infra/`)
so the two projects operate alike. The places where Storytime genuinely differs
— six services instead of one, four environments, a shared database, required
Redis, `eu-west-1` for data residency — are documented as differences rather than
papered over. No FateRound resource is imported or modified.

## Still hand-built, still not codified

- **Everything currently running.** Both boxes remain hand-built until a
  migration is planned and executed; this repository does not change them.
- **Dockerfiles.** No app repo has one. Nothing in `infra/` can run until they
  exist, and each needs the right Node base (fe >= 24, superadmin 20, backend 22).
- **The shared RDS.** Referenced read-only. Splitting it per environment is a
  data-migration project, off by default.
- **DNS.** Hand-edited at Namecheap, TTL 1800. All Cloudflare support is off by
  default.
- **The log viewer** (`logs.py`, a CGI behind nginx + fcgiwrap). No service entry
  yet.
- **CI workflows** to build and push images. Not written.
- **Observability.** No metrics, no alerting, no log shipping in this repo.

The full list, with the decisions each one is waiting on, is in
[`infra/README.md` → Open decisions](infra/README.md#open-decisions).

## Conventions

- Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Branch prefixes: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`.
- Default branch: `main`.
- Secrets never enter this repository. Not in tfvars, not in a capture, not in a
  vault file with a placeholder key. `secret_keys` (names) is committed;
  `secret_values` is not.
