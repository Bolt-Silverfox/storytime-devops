# Host capture

Read-only inventory of the two hand-built Storytime hosts.

Nothing else in this repository can be finished until this has been run, because
the current state of those boxes is undocumented. In particular the nginx vhosts
for `api`, `dev.api`, `staging.api`, `admin`, `dev.admin` and the apex marketing
site **exist only on disk and are in no repository at all**. The same is true of
the certificate renewal mechanism, the real listening ports of the two waitlist
API processes, and the actual set of environment variables each app needs.

Order of work for the whole repo: **capture → codify → provision.**

## What it produces

`capture/captures/<hostname>-<UTC timestamp>/`, containing:

| Directory | Contents |
|---|---|
| `00-MANIFEST.txt` | every command run, and its exit status |
| `10-system/` | OS release, kernel, CPU count, memory, disk + inode free, timezone, unattended-upgrades, pending-reboot flag |
| `20-node/` | node/npm versions, installed nvm versions, nvm default alias, global packages |
| `30-pm2/` | `pm2 jlist` **(masked)**, `~/.pm2/dump.pm2` **(masked)**, a per-process summary, whether a `pm2 startup` systemd unit exists and is enabled, log sizes |
| `40-nginx/` | **`nginx -T`** — the fully resolved config, every vhost — plus enabled sites, version, fcgiwrap status, which htpasswd files exist |
| `50-tls/` | `certbot certificates`, renewal configs, and whether renewal is a **systemd timer or a cron entry** |
| `60-redis/` | version, persistence mode, `maxmemory` + policy, whether `requirepass` is set, key count per logical DB, **BullMQ queue depths**, key-prefix histogram |
| `70-network/` | `ss -tlnp`, UFW status, iptables, fail2ban, interfaces, docker presence |
| `80-scheduled/` | user/root/system crontabs **(filtered)**, systemd timers, enabled units |
| `90-apps/` | per-app **environment variable NAMES**, git branch/HEAD, ecosystem file presence, `.nvmrc`/`engines` |
| `99-WARNINGS.txt` | what to check before committing, and any warnings raised |

## Secrets: the hard rule

**Names only. Never values.**

- Application configuration is recorded as `KEY=<set>` or `KEY=<empty>`.
- `pm2 jlist` embeds the **complete environment of every process** — on these
  boxes that is every database URL, JWT secret and third-party API key on the
  platform. It is masked before anything is written to disk.
- Redis `requirepass` is reported as set/unset. `CONFIG GET *` is never run.
- Redis key names and job payloads are never printed (they contain user and kid
  identifiers) — only counts and prefix histograms.
- `.htpasswd` contents and TLS private keys are not captured at all.
- Free-form text (`nginx -T`, crontabs) goes through a heuristic secret filter.

If `lib/redact.py` is missing, or fails on an input, the artefact is **skipped**
rather than written unredacted. Losing data is the correct failure mode.

> ### The heuristic filter is a safety net, not a guarantee.
> **Review the captured output before committing any of it.** `99-WARNINGS.txt`
> in every capture tells you exactly what to check.

Captures are **gitignored by default** (`capture/.gitignore`), so committing one
is an explicit act: `git add -f capture/captures/<host>-<timestamp>`. Please keep
it that way.

## Running it

It is **read-only**: it starts nothing, stops nothing, installs nothing, and
writes nothing outside its own output directory. Verify that claim yourself
before trusting it:

```bash
./capture-host.sh --list-commands     # prints every command; executes none
```

Run it **as the application user (`ubuntu`), not as root** — otherwise `pm2`
talks to root's daemon and you capture an empty process list. It uses `sudo -n`
for the handful of root-only reads (`nginx -T`, `certbot`, `ufw`, socket process
names) and records a note instead of failing when sudo is unavailable.

```bash
./capture-host.sh                       # -> ./captures/<host>-<ts>/
./capture-host.sh --out-dir /tmp/cap    # elsewhere
./capture-host.sh --timeout 120         # per-probe budget (default 60s)
```

Every probe is wrapped in `timeout`, so one slow command (`du` on a large
`/home`, a Redis `SCAN` over a big keyspace) records a timeout in the manifest
instead of hanging the run.

### Getting it onto a host

Two files are needed: `capture-host.sh` and `lib/redact.py`.

**Over SSH:**

Archive ONLY the two files, never `capture/.` — that would sweep up any existing
`captures/` output and ship previous (possibly unreviewed) captures to the host,
or into shell history via the base64 one-liner below.

```bash
tar czf - -C capture capture-host.sh lib | ssh ubuntu@<host> \
  'mkdir -p ~/st-capture && tar xzf - -C ~/st-capture && cd ~/st-capture && ./capture-host.sh'

# bring the result back
scp -r ubuntu@<host>:~/st-capture/captures/ ./capture/captures/
```

**Over SSM Session Manager** (no file transfer available — paste a bundle):

```bash
# locally: print a one-liner, then paste it into the session
echo "echo '$(tar czf - -C capture capture-host.sh lib | base64 -w0)' | base64 -d | tar xzf - -C ~/st-capture"
```

Then, inside the session:

```bash
mkdir -p ~/st-capture   # before pasting the above
cd ~/st-capture && ./capture-host.sh
```

To retrieve the result without a file transfer, `tar czf - captures | base64 -w0`
and copy it back out of the terminal.

## Then what

The capture is the **input to writing the Terraform**, specifically:

1. `90-apps/env-keys/*.keys.txt` → **split by hand** into
   `infra/terraform.<env>.tfvars`:
   - secret names → `var.secret_keys` (committed — names only), values into
     `var.secret_values` (gitignored, never committed) → SSM `SecureString`;
   - non-secret settings → `var.config_plain` as name **and** value, both
     committed → SSM `String`.

   **This step needs a human.** The capture reports every variable as
   `KEY=<set>` / `KEY=<empty>` and cannot tell which is which — that is the
   point of the redaction, not a gap in it. Routing everything to `secret_keys`
   would put non-secret settings into `SecureString` parameters *and* leave
   `config_plain` empty, so the shape of the environment stops being reviewable
   in a pull request.
2. `40-nginx/nginx-T.redacted.conf` → `hostnames`, `sse`, `max_body_size` and
   `read_timeout` per service in `var.services`.
3. `70-network/listening-sockets.txt` → the two **unknown** waitlist API ports.
4. `30-pm2/summary.txt` → replica counts, and which services need which Node
   version (which decides what each Dockerfile is based on).
5. `60-redis/bullmq-queues.txt` → whether that environment can tolerate
   `redis_mode = "container"` or needs ElastiCache.
