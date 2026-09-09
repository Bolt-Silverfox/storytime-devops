# Current state of Storytime infrastructure

Verified inventory of what exists **today**, before any of the Terraform in
`infra/` is applied. Written down because none of it was written down anywhere.

Treat this as the baseline to diff against. Where a fact is unknown it says so
rather than guessing; `capture/capture-host.sh` exists to close those gaps.

> **This repository is public.** Concrete addresses are therefore deliberately
> omitted: hosts are `host-a` / `host-b` and the database is
> `<shared-db-identifier>`. The real values belong in the **gitignored**
> `capture/captures/` output, or in a private document — not here. Publishing
> "this IP is production and this database also serves production" is a targeting
> aid even when the addresses themselves resolve publicly.

## Hosts

Two hand-built Ubuntu hosts, user `ubuntu`, **no IaC and no configuration
management of any kind**. Both in `eu-west-1`.

### `host-a` — shared multi-environment box (eu-west-1)

Runs dev **and** staging **and** blue **and** two production services at once:

- `dev.api`, `staging.api`, `blue.dev.api`
- `dev`, `dev.web`, `staging.web`, `blue.dev`
- `dev.admin`, `staging.admin`, `staging`
- `logs` (log viewer)
- **`waitlist` — production**
- `dev.waitlist`
- **`storytimeapp.me` apex marketing site, and `www`**

The last two matter: a dev deployment on this box can take down the public
marketing site and the production waitlist.

| PM2 process | Port |
|---|---|
| `storytime-api-development` | 3500 |
| `storytime-api-staging` | 3600 |
| `storytime-api-blue` | 3601 |
| `storytime-fe-dev` | 3674 |
| `storytime-fe-staging` | 3675 |
| `storytime-superadmin-dev` | 3505 |
| `storytime-superadmin-staging` | 3555 |
| `storytime-waitlist-development` | 3300 |
| `storytime-waitlist-production` | 4500 |
| `storytime-waitlist-api-development` | **unknown** (defaults to 3000) |
| `storytime-waitlist-api-production` | **unknown** (defaults to 3000) |

Plus `logs.py`, a CGI behind nginx + fcgiwrap with basic auth.

### `host-b` — dedicated production box (eu-west-1)

- `api`, `web`, `admin`

| PM2 process | Notes |
|---|---|
| `storytime-api-production` | cluster mode, `max(2, cpus-1)` workers |
| `storytime-fe-prod` | port 3000 |
| `storytime-superadmin-prod` | port 3505 |

## Database

**One** shared RDS Postgres instance, `<shared-db-identifier>` (eu-west-1),
resolving to a **public** IPv4 address:

```
<shared-db-identifier>.<id>.<region>.rds.amazonaws.com  ->  <public IPv4>
```

It serves **dev and staging and blue and prod simultaneously**, and it is
**publicly resolvable**. This is the single largest outstanding risk in the
platform: there is no database-level boundary between a developer's migration
and production data.

## Redis

Local to each box, **unmanaged**, shared across environments. Blue uses logical
database `/3`.

Logical databases are namespacing, not isolation — one `FLUSHALL`, one eviction
storm, or one `maxmemory` breach affects every environment sharing the instance.
BullMQ queues (email, push, story generation, TTS batch) live here, so an evicted
key is a job silently lost.

Persistence mode, `maxmemory` policy and whether `requirepass` is set are all
**unknown**; the capture script reports them.

## Process management

PM2. Every app's `ecosystem.config.js` lives in **its own app repo** and stays
there — this repository does not duplicate or move them.

**There is believed to be no `pm2 startup` systemd unit and no resurrection on
either box.** That means a reboot leaves every application down until a human
notices, and it is a known cause of past outages. Confirm with
`capture/captures/*/30-pm2/startup-units.txt`.

## Node

A genuine version conflict on the shared box:

| Component | Requirement |
|---|---|
| `storytime-fe` | Node **>= 24** |
| `storytime_superadmin` | Node **20** (pinned) |
| `storytime_be` CI | Node **22** |

One global Node cannot satisfy all three, so today this is juggled with nvm. In
the container model each service carries its own base image and the conflict
stops existing.

## TLS and DNS

- Certificates via certbot/Let's Encrypt. Whether renewal runs from a **systemd
  timer or a cron entry** is unknown, and so is whether it currently works.
- DNS is **hand-edited at Namecheap**, TTL 1800.
- **No CDN and no load balancer.** Public hostnames resolve straight to the two
  instance IPs.

## What is in no repository at all

The live nginx vhosts for `api`, `dev.api`, `staging.api`, `admin`, `dev.admin`
and the apex marketing site exist **only on the boxes' disks**. If either
instance were lost, that configuration would have to be reconstructed from
memory. Capturing `nginx -T` is the highest-value single artefact in
`capture/`.

## Known gaps this document cannot fill

Needs `capture/capture-host.sh` to be run against both hosts:

- the real listening ports of the two waitlist API processes
- the full resolved nginx configuration
- the certificate renewal mechanism, and whether it is healthy
- Redis version, persistence mode, `maxmemory` policy, `requirepass`, per-DB key
  counts and BullMQ queue depths
- the complete set of environment variable **names** each app needs
- whether a PM2 startup unit exists
- UFW and fail2ban state
- installed nvm versions and which interpreter each process actually uses
