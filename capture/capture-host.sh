#!/usr/bin/env bash
# =============================================================================
# capture-host.sh — read-only inventory of a hand-built Storytime host.
#
# WHY THIS EXISTS
# ---------------
# Nobody knows what the two live boxes actually run. The nginx vhosts for api,
# dev.api, staging.api, admin, dev.admin and the apex marketing site exist ONLY
# on disk and are in no repository. The certificate renewal mechanism, the Redis
# persistence settings, the real listening ports and the actual set of
# environment variables each app needs are all undocumented. You cannot codify
# infrastructure you cannot see, so this runs FIRST: capture -> codify -> provision.
#
# WHAT IT IS
# ----------
# READ-ONLY. It starts no service, stops no service, writes nothing outside its
# own output directory, and installs nothing. Run `--list-commands` to print
# every command it would execute, without executing any of them, and check that
# claim yourself before trusting it.
#
# THE HARD RULE ABOUT SECRETS
# ---------------------------
# This script must be safe to run and safe to commit the output of. Therefore:
#
#   *  For application configuration it records NAMES ONLY. Every value is
#      reported as `KEY=<set>` or `KEY=<empty>`. Never the value.
#   *  `pm2 jlist` embeds the COMPLETE environment of every process — on these
#      boxes that is every database URL, JWT secret and third-party API key on
#      the platform. It is masked before it is written.
#   *  Redis `requirepass` is reported as set/unset. `CONFIG GET *` is never run.
#   *  Text artefacts (nginx -T, crontabs) go through a heuristic secret filter.
#
# That filter is a SAFETY NET, NOT A GUARANTEE.
#
#      >>> READ THE CAPTURED OUTPUT BEFORE YOU COMMIT IT. <<<
#
# Captures are gitignored by default (see capture/.gitignore), so committing one
# is an explicit, deliberate act. Keep it that way.
#
# If lib/redact.py is missing or fails on an input, the artefact is SKIPPED
# rather than written unredacted. Losing data is the correct failure mode here.
#
# USAGE
# -----
#   ./capture-host.sh                     # capture into ./captures/<host>-<ts>/
#   ./capture-host.sh --out-dir /tmp/cap  # somewhere else
#   ./capture-host.sh --list-commands     # print the plan, run nothing
#
# Run it as the application user (`ubuntu`) — NOT as root — so that `pm2` talks to
# the right daemon. It uses `sudo -n` for the handful of root-only reads
# (nginx -T, certbot, ufw, socket process names) and records a note instead of
# failing when sudo is unavailable.
# =============================================================================

# NOT `set -e`: almost every probe below is expected to fail on a host that
# doesn't have that particular tool, and the run must continue and record the
# absence. Failures are handled explicitly, per probe.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REDACT="$SCRIPT_DIR/lib/redact.py"

OUT_ROOT="$SCRIPT_DIR/captures"
LIST_ONLY=0
# Per-probe wall-clock budget. A single hung probe must not hang the capture —
# `du` on a big /home and a Redis SCAN on a large keyspace are both slow enough
# to matter, and this may be running in a Session Manager shell.
TIMEOUT_S=60

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_ROOT="${2:?--out-dir needs a path}"; shift 2 ;;
    --timeout) TIMEOUT_S="${2:?--timeout needs seconds}"; shift 2 ;;
    --list-commands) LIST_ONLY=1; shift ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s 2>/dev/null || echo unknown)
OUT="$OUT_ROOT/$HOST-$TS"
WARNINGS=""

have() { command -v "$1" >/dev/null 2>&1; }

# Bound every probe. SIGTERM first, SIGKILL 5s later if it ignores that.
# Exit code 124 from `timeout` shows up in 00-MANIFEST.txt, so a probe that timed
# out is visibly different from one whose tool is missing.
TIMEOUT=()
if have timeout; then
  TIMEOUT=(timeout --signal=TERM --kill-after=5 "$TIMEOUT_S")
fi

# sudo, non-interactive only. Never prompts, never hangs a Session Manager shell.
SUDO=""
if [ "$(id -u)" = "0" ]; then
  SUDO=""
elif have sudo && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi

warn() {
  echo "  ! $1" >&2
  WARNINGS="${WARNINGS}$1"$'\n'
}

# ---------------------------------------------------------------------------
# run <relative-output-path> <command...>
#
# Captures stdout+stderr of a command into the output tree. Records the exact
# command and its exit status in the manifest, so a missing artefact is always
# distinguishable from a tool that isn't installed.
# ---------------------------------------------------------------------------
run() {
  local dest="$1"; shift
  if [ "$LIST_ONLY" = "1" ]; then
    printf '%-46s %s\n' "$dest" "$*"
    return 0
  fi
  mkdir -p "$(dirname "$OUT/$dest")"
  {
    echo "\$ $*"
    echo "---"
  } > "$OUT/$dest"
  if "${TIMEOUT[@]}" "$@" >> "$OUT/$dest" 2>&1; then
    echo "ok     $dest  <- $*" >> "$OUT/00-MANIFEST.txt"
  else
    local rc=$?
    if [ "$rc" = "124" ]; then
      warn "TIMEOUT after ${TIMEOUT_S}s: $dest  <- $*"
    fi
    echo "rc=$rc  $dest  <- $*" >> "$OUT/00-MANIFEST.txt"
  fi
}

# ---------------------------------------------------------------------------
# run_redacted <mode> <relative-output-path> <command...>
#
# Same, but the output passes through lib/redact.py first. If the redactor is
# absent or errors, NOTHING is written — the artefact is dropped and a warning
# recorded. This is the fail-safe that makes the whole script committable.
# ---------------------------------------------------------------------------
run_redacted() {
  local mode="$1" dest="$2"; shift 2
  if [ "$LIST_ONLY" = "1" ]; then
    printf '%-46s %s\n' "$dest" "$* | redact.py $mode"
    return 0
  fi

  if [ ! -f "$REDACT" ] || ! have python3; then
    warn "SKIPPED $dest — redactor unavailable (need python3 and $REDACT). Refusing to write unredacted output."
    return 0
  fi

  local raw redacted
  raw=$(mktemp); redacted=$(mktemp)
  chmod 600 "$raw" "$redacted"

  "${TIMEOUT[@]}" "$@" > "$raw" 2>/dev/null
  local rc=$?

  if python3 "$REDACT" "$mode" < "$raw" > "$redacted" 2>/dev/null; then
    mkdir -p "$(dirname "$OUT/$dest")"
    {
      echo "\$ $* | redact.py $mode   (exit=$rc)"
      echo "# VALUES ARE MASKED. Review before committing."
      echo "---"
      cat "$redacted"
    } > "$OUT/$dest"
    echo "ok     $dest  <- $* [redacted:$mode]" >> "$OUT/00-MANIFEST.txt"
  else
    warn "SKIPPED $dest — redact.py '$mode' failed on the input; refusing to write it unredacted."
  fi

  # Shred the intermediate: it held real secrets.
  rm -f "$raw" "$redacted"
}

note() {
  local dest="$1" text="$2"
  [ "$LIST_ONLY" = "1" ] && return 0
  mkdir -p "$(dirname "$OUT/$dest")"
  printf '%s\n' "$text" >> "$OUT/$dest"
}

if [ "$LIST_ONLY" = "0" ]; then
  mkdir -p "$OUT"
  chmod 700 "$OUT"
  echo "capturing $HOST into $OUT"
  {
    echo "storytime host capture"
    echo "host:      $HOST"
    echo "fqdn:      $(hostname -f 2>/dev/null || echo unknown)"
    echo "captured:  $TS (UTC)"
    echo "as user:   $(id -un) (uid $(id -u))"
    echo "sudo -n:   ${SUDO:-unavailable}"
    echo
    echo "All application configuration VALUES are masked. See 99-WARNINGS.txt."
    echo
  } > "$OUT/00-MANIFEST.txt"
else
  echo "# commands capture-host.sh would run (nothing is being executed)"
  echo
fi

# =============================================================================
# 10 — system
# =============================================================================
run 10-system/os-release.txt        cat /etc/os-release
run 10-system/kernel.txt            uname -a
run 10-system/uptime.txt            uptime
run 10-system/cpu.txt               lscpu
run 10-system/cpu-count.txt         nproc
run 10-system/memory.txt            free -m
run 10-system/disk-free.txt         df -h
run 10-system/disk-inodes.txt       df -i
run 10-system/timezone.txt          timedatectl
# --max-depth=1 and node_modules excluded: an unbounded `du` over /home on a box
# with several Node app checkouts takes minutes and is the one probe most likely
# to blow the timeout.
run 10-system/largest-dirs.txt      du -xh --max-depth=1 --exclude=node_modules /var /home
run 10-system/unattended-upgrades.txt cat /etc/apt/apt.conf.d/20auto-upgrades
run 10-system/reboot-required.txt   ls -l /var/run/reboot-required

# =============================================================================
# 20 — Node / nvm
#
# The shared box has a genuine version conflict: the web frontend requires
# Node >= 24, superadmin pins Node 20, and backend CI uses 22. Capture what is
# actually installed and, crucially, WHICH INTERPRETER EACH PM2 PROCESS IS USING
# (see 30-pm2), because that is the fact that decides whether containerising each
# service per-version is necessary or merely tidy.
# =============================================================================
run 20-node/node-version.txt        node --version
run 20-node/npm-version.txt         npm --version
run 20-node/which-node.txt          bash -lc 'command -v node; command -v npm; command -v pnpm; command -v pm2'
run 20-node/nvm-installed.txt       bash -lc 'ls -1 "${NVM_DIR:-$HOME/.nvm}/versions/node" 2>/dev/null'
run 20-node/nvm-current.txt         bash -lc 'source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1 && nvm ls'
run 20-node/nvm-alias-default.txt   bash -lc 'cat "${NVM_DIR:-$HOME/.nvm}/alias/default" 2>/dev/null'
run 20-node/global-packages.txt     npm ls -g --depth=0
run 20-node/corepack.txt            corepack --version

# =============================================================================
# 30 — PM2
#
# `pm2 jlist` is the single richest artefact on the box AND the most dangerous:
# it contains every process's full environment. It is masked (names kept, values
# replaced) before anything is written.
#
# Also capture whether a `pm2 startup` systemd unit exists at all. The boxes are
# believed to have NO resurrection unit, which means a reboot leaves every app
# down until a human notices — a known outage cause. Confirm it here.
# =============================================================================
run          30-pm2/list.txt         pm2 list
run          30-pm2/pm2-version.txt  pm2 --version
run_redacted pm2-json 30-pm2/jlist.redacted.json  pm2 jlist
run_redacted pm2-json 30-pm2/dump.pm2.redacted.json cat "$HOME/.pm2/dump.pm2"
run          30-pm2/dump-exists.txt  ls -l "$HOME/.pm2/dump.pm2" "$HOME/.pm2/dump.pm2.bak"
run          30-pm2/startup-units.txt bash -c 'ls -l /etc/systemd/system/pm2-*.service 2>&1; echo "---"; systemctl list-unit-files "pm2-*" 2>&1'
run          30-pm2/startup-enabled.txt bash -c 'for u in /etc/systemd/system/pm2-*.service; do [ -e "$u" ] || continue; n=$(basename "$u"); echo "$n: $(systemctl is-enabled "$n" 2>&1) / $(systemctl is-active "$n" 2>&1)"; done'
run          30-pm2/logrotate.txt    pm2 conf pm2-logrotate
run          30-pm2/log-sizes.txt    bash -c 'du -sh "$HOME/.pm2/logs" 2>&1; ls -lhS "$HOME/.pm2/logs" 2>&1 | head -40'

# Per-process interpreter + exec mode + restart counts, extracted from the
# already-masked jlist so this adds no new exposure.
if [ "$LIST_ONLY" = "0" ] && [ -f "$OUT/30-pm2/jlist.redacted.json" ] && have python3; then
  tail -n +4 "$OUT/30-pm2/jlist.redacted.json" | python3 -c '
import json, sys
try:
    apps = json.load(sys.stdin)
except Exception as exc:
    print("could not parse masked jlist:", exc); raise SystemExit(0)
row = "{:<38} {:<10} {:<4} {:<9} {:<9} {}"
print(row.format("name", "mode", "inst", "status", "restarts", "cwd"))
for a in apps:
    e = a.get("pm2_env", {}) or {}
    print(row.format(
        str(a.get("name")), str(e.get("exec_mode")), str(e.get("instances")),
        str(e.get("status")), str(e.get("restart_time")), str(e.get("pm_cwd"))))
' > "$OUT/30-pm2/summary.txt" 2>&1
fi

# =============================================================================
# 40 — nginx
#
# `nginx -T` is THE artefact this whole exercise exists for: the fully resolved
# configuration, every vhost, every include. None of it is in any repository.
#
# It goes through the text redactor, which can MANGLE a line it decides to mask
# (an inline bearer token in a proxy_set_header, say). That is deliberate: a
# slightly damaged directive you have to re-read from the box beats a leaked
# credential in a git history. Diff against the box when reconstructing.
# =============================================================================
run          40-nginx/nginx-version.txt  bash -c "$SUDO nginx -v 2>&1; $SUDO nginx -V 2>&1"
run_redacted text 40-nginx/nginx-T.redacted.conf bash -c "$SUDO nginx -T"
run          40-nginx/sites-enabled.txt  bash -c 'ls -l /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>&1'
run          40-nginx/nginx-status.txt   systemctl status nginx --no-pager
run          40-nginx/fcgiwrap.txt       bash -c 'systemctl status fcgiwrap --no-pager 2>&1; ls -l /etc/nginx/*fcgi* 2>&1'
run          40-nginx/htpasswd-files.txt bash -c "$SUDO find /etc/nginx -name '*.htpasswd*' -o -name '.htpasswd*' 2>/dev/null | xargs -r ls -l"
note         40-nginx/README.txt "The log viewer (logs.py) runs as a CGI behind nginx + fcgiwrap with basic auth."
note         40-nginx/README.txt "htpasswd FILE CONTENTS ARE DELIBERATELY NOT CAPTURED (they are password hashes) - only that the files exist."

# =============================================================================
# 50 — TLS / certbot
#
# Which mechanism renews certificates matters: a systemd timer and a cron entry
# fail in different ways, and one of them may already be broken. Capture both
# possibilities rather than assuming.
# =============================================================================
run 50-tls/certbot-certificates.txt bash -c "$SUDO certbot certificates"
run 50-tls/certbot-version.txt      bash -c "$SUDO certbot --version"
run 50-tls/renewal-timer.txt        bash -c 'systemctl list-timers "*certbot*" "*acme*" --all --no-pager 2>&1; echo "--- unit files ---"; systemctl list-unit-files "*certbot*" 2>&1; echo "--- is-enabled ---"; systemctl is-enabled certbot.timer 2>&1; systemctl is-active certbot.timer 2>&1'
run 50-tls/renewal-cron.txt         bash -c "ls -l /etc/cron.d/ 2>&1; echo '--- certbot in cron ---'; $SUDO grep -rl certbot /etc/cron.d /etc/crontab /etc/cron.daily 2>/dev/null"
run 50-tls/renewal-configs.txt      bash -c "$SUDO ls -l /etc/letsencrypt/renewal/ 2>&1"
run 50-tls/live-certs.txt           bash -c "$SUDO ls -l /etc/letsencrypt/live/ 2>&1"
run 50-tls/dry-run-note.txt         bash -c 'echo "A renewal dry-run is NOT performed by this script: certbot --dry-run contacts the ACME staging server and is not a pure read. Run it yourself if you want it: sudo certbot renew --dry-run"'

# =============================================================================
# 60 — Redis
#
# Unmanaged, local to the box, shared across every environment, with blue merely
# using logical DB /3. Capture enough to decide between ElastiCache and a
# container, and to size it.
#
# `CONFIG GET *` IS NEVER RUN — it would return requirepass. Only named,
# non-secret parameters are read, and requirepass is reported as set/unset only.
# =============================================================================
if have redis-cli; then
  run 60-redis/ping.txt        redis-cli ping
  run 60-redis/server-info.txt redis-cli info server
  run 60-redis/memory.txt      redis-cli info memory
  run 60-redis/persistence.txt redis-cli info persistence
  run 60-redis/clients.txt     redis-cli info clients
  run 60-redis/stats.txt       redis-cli info stats
  run 60-redis/keyspace.txt    redis-cli info keyspace
  run 60-redis/replication.txt redis-cli info replication

  # Named parameters only. Values here are operational settings, not credentials.
  run 60-redis/config-safe.txt bash -c '
    for p in maxmemory maxmemory-policy maxmemory-samples appendonly appendfsync \
             save dir dbfilename appendfilename databases timeout tcp-keepalive \
             stop-writes-on-bgsave-error rdbcompression lazyfree-lazy-eviction \
             notify-keyspace-events bind protected-mode port unixsocket; do
      printf "%-30s %s\n" "$p" "$(redis-cli config get "$p" 2>/dev/null | tail -1)"
    done'

  # requirepass: existence only, never the value.
  run 60-redis/requirepass.txt bash -c '
    v=$(redis-cli config get requirepass 2>/dev/null | tail -1)
    if [ -z "$v" ]; then
      echo "requirepass=<empty>   # Redis accepts unauthenticated connections"
    else
      echo "requirepass=<set>"
    fi
    echo
    echo "# NOTE: an empty requirepass on a box whose Redis is shared by every"
    echo "# environment means any local process can FLUSHALL every queue."'

  # BullMQ queue depths, per logical database. Storytime uses BullMQ for the
  # email, push, story-generation and TTS-batch queues; a deep `wait` or a large
  # `failed` set is exactly the kind of thing nobody has been able to see.
  #
  # SCAN (not KEYS) so this never blocks the server. Queue NAMES are printed but
  # queue CONTENTS never are — job payloads contain user data.
  run 60-redis/bullmq-queues.txt bash -c '
    dbcount=$(redis-cli config get databases 2>/dev/null | tail -1); dbcount=${dbcount:-16}
    for db in $(seq 0 $((dbcount - 1))); do
      keys=$(redis-cli -n "$db" dbsize 2>/dev/null)
      [ "${keys:-0}" = "0" ] && continue
      echo "=== logical DB $db  (dbsize=$keys) ==="
      queues=$(redis-cli -n "$db" --scan --pattern "bull:*:meta" --count 200 2>/dev/null \
                 | sed -e "s/^bull://" -e "s/:meta$//" | sort -u)
      if [ -z "$queues" ]; then echo "  (no BullMQ queues found)"; echo; continue; fi
      printf "  %-34s %8s %8s %8s %10s %8s %8s\n" queue wait active delayed completed failed paused
      for q in $queues; do
        printf "  %-34s %8s %8s %8s %10s %8s %8s\n" "$q" \
          "$(redis-cli -n "$db" llen  "bull:$q:wait"      2>/dev/null)" \
          "$(redis-cli -n "$db" llen  "bull:$q:active"    2>/dev/null)" \
          "$(redis-cli -n "$db" zcard "bull:$q:delayed"   2>/dev/null)" \
          "$(redis-cli -n "$db" zcard "bull:$q:completed" 2>/dev/null)" \
          "$(redis-cli -n "$db" zcard "bull:$q:failed"    2>/dev/null)" \
          "$(redis-cli -n "$db" llen  "bull:$q:paused"    2>/dev/null)"
      done
      echo
    done'

  # Key-prefix histogram: shows which environments share this instance, without
  # printing key names (which embed user and kid identifiers).
  run 60-redis/key-prefix-histogram.txt bash -c '
    dbcount=$(redis-cli config get databases 2>/dev/null | tail -1); dbcount=${dbcount:-16}
    for db in $(seq 0 $((dbcount - 1))); do
      keys=$(redis-cli -n "$db" dbsize 2>/dev/null)
      [ "${keys:-0}" = "0" ] && continue
      echo "=== logical DB $db (dbsize=$keys) — first two path segments only ==="
      redis-cli -n "$db" --scan --count 500 2>/dev/null \
        | awk -F: "{ if (NF>=2) print \$1\":\"\$2; else print \$1 }" \
        | sort | uniq -c | sort -rn | head -25
      echo
    done'

  run 60-redis/service.txt systemctl status redis-server --no-pager
  run 60-redis/config-file.txt bash -c "$SUDO ls -l /etc/redis/ 2>&1"
else
  note 60-redis/ABSENT.txt "redis-cli not found on PATH — Redis may still be running (check 70-network/listening-sockets.txt for :6379)."
fi

# =============================================================================
# 70 — network / firewall
# =============================================================================
run 70-network/listening-sockets.txt bash -c "$SUDO ss -tlnp"
run 70-network/listening-udp.txt     bash -c "$SUDO ss -ulnp"
run 70-network/established-count.txt bash -c 'ss -tn state established | wc -l'
run 70-network/ufw-status.txt         bash -c "$SUDO ufw status verbose"
run 70-network/iptables-summary.txt   bash -c "$SUDO iptables -S"
run 70-network/fail2ban.txt           bash -c "systemctl status fail2ban --no-pager 2>&1; echo '--- jails ---'; $SUDO fail2ban-client status 2>&1"
run 70-network/interfaces.txt         ip -brief address
run 70-network/resolv.txt             bash -c 'cat /etc/resolv.conf 2>&1; echo "--- hosts ---"; cat /etc/hosts'
run 70-network/docker.txt             bash -c 'command -v docker >/dev/null && { docker --version; docker ps -a; } 2>&1 || echo "docker not installed"'

# =============================================================================
# 80 — scheduled work
#
# Crontabs are redacted as text: a cron line is a shell command and people put
# tokens in them.
# =============================================================================
run_redacted text 80-scheduled/crontab-user.txt   crontab -l
run_redacted text 80-scheduled/crontab-root.txt   bash -c "$SUDO crontab -l"
run_redacted text 80-scheduled/crontab-system.txt bash -c "$SUDO cat /etc/crontab 2>/dev/null; echo '--- /etc/cron.d ---'; $SUDO grep -rH . /etc/cron.d/ 2>/dev/null"
run 80-scheduled/cron-dirs.txt       bash -c 'ls -l /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>&1'
run 80-scheduled/systemd-timers.txt  systemctl list-timers --all --no-pager
run 80-scheduled/systemd-enabled.txt bash -c 'systemctl list-unit-files --state=enabled --no-pager'

# =============================================================================
# 90 — application environment variable NAMES
#
# The point of the whole capture: what configuration does each app actually need?
# NAMES ONLY. Every value becomes <set> or <empty>.
#
# App directories are discovered from the masked pm2 jlist (pm_cwd), so this
# follows reality rather than a guessed path layout.
# =============================================================================
if [ "$LIST_ONLY" = "1" ]; then
  echo "90-apps/env-keys/<app>.keys.txt              <each pm2 cwd>/.env* | redact.py env-keys"
else
  APP_DIRS=""
  if [ -f "$OUT/30-pm2/jlist.redacted.json" ] && have python3; then
    APP_DIRS=$(tail -n +4 "$OUT/30-pm2/jlist.redacted.json" | python3 -c '
import json, sys
try:
    apps = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
seen = []
for a in apps:
    cwd = (a.get("pm2_env") or {}).get("pm_cwd") or (a.get("pm2_env") or {}).get("cwd")
    if cwd and cwd not in seen:
        seen.append(cwd)
print("\n".join(seen))
' 2>/dev/null)
  fi

  if [ -z "$APP_DIRS" ]; then
    warn "Could not derive app directories from pm2 — 90-apps/env-keys is empty. Re-run as the user that owns the pm2 daemon (ubuntu)."
    note 90-apps/env-keys/NONE.txt "No app directories discovered. See 99-WARNINGS.txt."
  fi

  for dir in $APP_DIRS; do
    [ -d "$dir" ] || continue
    app=$(basename "$dir")
    # -maxdepth 1: only the app's own env files, never a node_modules fixture.
    while IFS= read -r envfile; do
      [ -n "$envfile" ] || continue
      label="$app$(printf '%s' "$envfile" | sed -e "s#^$dir##" -e 's#/#_#g')"
      run_redacted env-keys "90-apps/env-keys/${label}.keys.txt" cat "$envfile"
      run "90-apps/env-keys/${label}.stat.txt" stat -c '%n mode=%A owner=%U:%G size=%s mtime=%y' "$envfile"
    done < <(find "$dir" -maxdepth 1 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' \) 2>/dev/null | sort)

    run "90-apps/${app}.git.txt" bash -c "cd '$dir' 2>/dev/null && { git rev-parse --abbrev-ref HEAD; git log -1 --format='%H %ad %an %s'; git status --porcelain | head -40; } 2>&1"
    run "90-apps/${app}.ecosystem.txt" bash -c "ls -l '$dir'/ecosystem*.js '$dir'/ecosystem*.cjs 2>&1"
    run "90-apps/${app}.node-version.txt" bash -c "cat '$dir'/.nvmrc 2>/dev/null; echo '--- engines ---'; python3 -c \"import json;print(json.load(open('$dir/package.json')).get('engines'))\" 2>/dev/null"
  done
fi

# =============================================================================
# 99 — warnings
# =============================================================================
if [ "$LIST_ONLY" = "0" ]; then
  {
    echo "==================================================================="
    echo " REVIEW THIS CAPTURE BEFORE COMMITTING ANY OF IT"
    echo "==================================================================="
    echo
    echo "Configuration VALUES were masked: application config appears as"
    echo "KEY=<set> / KEY=<empty>, and pm2 process environments are masked."
    echo
    echo "The masking of free-form text (nginx -T, crontabs) is HEURISTIC."
    echo "It is a safety net, not a guarantee. Before committing, at minimum:"
    echo
    echo "  1. grep the whole capture for anything that looks like a credential:"
    echo "       grep -rniE 'secret|token|password|api[_-]?key|bearer|BEGIN .*PRIVATE' ."
    echo "  2. read 40-nginx/nginx-T.redacted.conf end to end."
    echo "  3. read 80-scheduled/crontab-*.txt end to end."
    echo
    echo "Captures are gitignored by default (capture/.gitignore). Committing one"
    echo "must stay a deliberate act — do not relax that ignore rule."
    echo
    echo "Artefacts intentionally NOT captured:"
    echo "  - .htpasswd contents (password hashes)"
    echo "  - Redis requirepass value, and any output of CONFIG GET *"
    echo "  - Redis key names and job payloads (user data): counts and prefixes only"
    echo "  - TLS private keys"
    echo "  - a certbot renewal dry-run (it contacts the ACME server; not a read)"
    echo
    if [ -n "$WARNINGS" ]; then
      echo "Warnings raised during this run:"
      printf '%s' "$WARNINGS" | sed 's/^/  - /'
    else
      echo "No warnings raised during this run."
    fi
  } > "$OUT/99-WARNINGS.txt"

  echo
  echo "done: $OUT"
  echo "artefacts: $(find "$OUT" -type f | wc -l)"
  echo
  echo "NEXT: read $OUT/99-WARNINGS.txt, then review the capture before committing it."
fi
