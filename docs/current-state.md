# Current state of Storytime infrastructure

What exists **today**, after the September 2026 rebuild. The previous version of
this file described two hand-built Ubuntu hosts in an AWS account we lost access
to; none of that survives, and none of it is described here.

> **This repository is public.** Concrete identifiers are therefore deliberately
> omitted: the instance, the Elastic IP, the RDS endpoint, the AWS account and
> the Grafana stack are all referred to generically. The real values are in
> `terraform output` (gitignored state), in `infra/terraform.prod.tfvars` (also
> gitignored), or in the AWS console. Publishing "this address is production"
> is a targeting aid even when the address resolves publicly.

## Shape

One EC2 instance runs every service as a Docker container behind Caddy, with a
managed Postgres alongside. There is **one environment: production**. There is
no staging and no dev stack — `terraform apply` is always a production change.

    Internet ──► Caddy (TLS, :443) ──► five app containers on the loopback
                                  └──► redis container

| | |
|---|---|
| Instance | 1× `t4g.small` (2 GiB, **arm64/Graviton**), eu-west-1, one Elastic IP |
| Images | ECR, `storytime/<service>`, **linux/arm64 only** |
| Database | RDS PostgreSQL 16.15, `db.t4g.micro`, 20 GB, **not publicly accessible**, 7-day backups |
| Redis | a container on the box, **not** ElastiCache |
| TLS | Caddy + Let's Encrypt (ACME), auto-renewing |
| DNS | hand-edited at Namecheap, TTL 1800 |
| Config | AWS SSM Parameter Store |
| Telemetry | Grafana Cloud over OTLP |

`instance_type` drives the AMI architecture (`compute.tf`), so a `t4g` selects
an arm64 AMI and the arm64 Caddy checksum. **Container images must be built
`linux/arm64`** or the box boots with nothing running.

## Services and hostnames

| Service | Host | Container:host port | Memory |
|---|---|---|---|
| `api` | `api.storytimeapp.me` | 3000:3000 | 512 MiB |
| `web` | `web.storytimeapp.me` | 3000:3100 | 256 MiB |
| `admin` | `admin.storytimeapp.me` | 3505:3505 | 256 MiB |
| `waitlist-web` | apex, `www`, `waitlist.` | 4500:4500 | 256 MiB |
| `waitlist-api` | `api.waitlist.storytimeapp.me` | 3000:4600 | 192 MiB |

The **apex and `www` serve the marketing site**, not the app — that is a
deliberate change from the pre-rebuild arrangement, where the apex was the web
app. `WEB_APP_BASE_URL` therefore points at `web.`, and it is the OAuth redirect
target (`auth.controller.ts`).

`waitlist-api` needs a public hostname even though nothing links to it directly:
the marketing site calls it **from the browser** in client components, so an
internal-only route would leave every form silently failing.

## Memory budget

The pool is `instance_ram − host_reserve − redis`, and a Terraform precondition
(`guards.tf`) fails the **plan** if the services exceed it — deliberately, so a
bad allocation is caught before it OOM-kills a container at 03:00.

    2048 − 400 host reserve − 128 redis = 1520 available
    512 + 256 + 256 + 256 + 192         = 1472 committed      48 MiB slack

Those numbers are **measured** against the real arm64 images under their own
caps, not estimated. Two were wrong before measurement: `waitlist-web` at
176 MiB was OOM-killed by the kernel, and `admin` at 224 MiB sat at 94%.

**Every Node container needs an explicit `--max-old-space-size`.** Measured on
cgroup v2, identical on Node 22 and 24: V8 reports a `heap_size_limit` of
259 MiB at caps of 160/192/224/256/384/512 MiB alike. It tracks the cgroup limit
above ~512 MiB but has a ~259 MiB **floor** below it, so a 256 MiB container
runs a V8 that believes it may grow past its cap and is OOM-killed before it
ever GCs. The flags are set per service in `config_plain`, not baked into
images, so retuning one costs an apply rather than a rebuild.

There is 48 MiB of slack, so allocations can grow by up to that in total
before the guard fails the plan — not "any increase breaks it". Once it does,
the move is `t4g.medium` (~2× the instance cost), not shaving the host reserve.

## Configuration

Parameters live at `/storytime-<env>/<service>/<KEY>` and reach containers as a
docker `--env-file`, which **overrides the image's own `ENV`**. The instance
role can **read** SSM (with decryption) but cannot write it.

Two consequences worth knowing:

- `NEXT_PUBLIC_*` values are inlined into the JS bundle at **build** time, so
  they are Docker build args and **one image per environment** is unavoidable.
  Setting them in SSM does nothing.
- After changing SSM, `docker restart` is **not** enough — it reuses the
  env-file materialised at boot. Use `systemctl start storytime-reconcile`,
  which regenerates each service's env-file and recreates the containers.

## Database

One RDS instance, two databases: the application database (live schema
`storytime`; a legacy `public` schema also exists from the restore and is dead),
and a separate waitlist database, currently empty — the pre-rebuild waitlist
data was lost with the old account.

Not publicly accessible. Reach it through the box:

    aws ssm start-session --region eu-west-1 --target <instance-id> \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["55432"]}'

## Backups

Nightly `pg_dump` to S3 plus a restore-verification unit, and DLM EBS snapshots.
RDS keeps 7 days of automated backups. The nightly dump is the layer to check
first; it writes a status object the `restore_verification_check` output reads.

## Observability

Traces, logs and metrics push to Grafana Cloud over OTLP. Four alert rules live
in `observability/alert-rules.yaml` (api down, 5xx rate, event-loop stall, TLS
expiry) and notify a shared email contact point.

**Only `api` reports.** `web`, `admin`, `waitlist-web` and `waitlist-api` emit
no telemetry, so the alerting covers one of five services.

Two non-obvious things, both learned the hard way:

- `OTEL_METRICS_EXPORTER` defaults to `prometheus`, which starts a **pull**-based
  exporter nothing scrapes, while logging a cheerful "metrics available at
  localhost:9464". It must be set to `otlp`.
- TLS expiry is measured by an hourly systemd timer on the box that pushes
  `tls_cert_expiry_seconds` per hostname. Because the push is hourly and
  Prometheus considers a sample current for ~5 minutes, the alert queries
  `max_over_time(...[2h])` — an instant query would report No Data for 55
  minutes of every hour.

## Deploying

`user_data_replace_on_change = true`, so **any change to the bootstrap script
replaces the instance** — a few minutes of downtime across all five services.
That is deliberate. Without it, Terraform would update the user data attribute
in place and the instance would keep running the script it booted with, so a
bootstrap change would appear to apply cleanly while changing nothing.

User data is `base64gzip`-ed because EC2 caps it at 16384 bytes after decoding
and the rendered script is ~32 KB. Note `user_data_base64` has **no** length
validation in the provider, so the next overflow fails at `RunInstances` during
apply rather than at plan. Current headroom is roughly 4.7 KB.

## Known gaps

- Four of five services emit no telemetry.
- No synthetic/external uptime check; an outage is noticed from inside.
- `health_path` in `terraform.prod.tfvars` is **dead config** — nothing reads it.
  Neither Caddy nor the bootstrap health-checks an upstream, so a wedged but
  listening container stays in rotation.
- `X-API-Key` is not validated anywhere. The frontends still send it; the
  gateway that enforced it is gone.
- Redis is a container, so a box replacement drops every queued job.
- One environment only. There is nowhere to rehearse a change.
