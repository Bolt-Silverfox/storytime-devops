#!/usr/bin/env bash
#
# Local harness for the safety rails in .github/workflows/build-and-deploy.yml.
#
# WHY THIS EXISTS: the deploy logic cannot be exercised on production, and the
# interesting behaviour is all in failure paths (unhealthy image, failed
# migration, a second deploy racing the first). So this extracts the workflow's
# REAL step scripts, runs them against stubbed `aws`, `docker`, `curl` and
# `redeploy.sh`, and asserts on what was (and was not) done.
#
# What is real: the step scripts as shipped in the YAML, the jq program that
# assembles the SSM payload, the payload run through `sh` exactly as
# AWS-RunShellScript would run it, and (where the OS has it) util-linux flock.
# What is stubbed: everything that talks to AWS, Docker or the network.
# What this does NOT prove: that real Docker health semantics, real prisma, or
# real SSM behave as the stubs assume. See docs/build-and-deploy.md.
#
# Usage: tests/deploy/run-tests.sh            (SH=dash to pick the payload shell)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WF="$ROOT/.github/workflows/build-and-deploy.yml"
PAYLOAD_SH="${SH:-sh}"

TMP="$(mktemp -d)"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CURRENT: $1"); printf '  FAIL %s\n' "$1"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_contains() { # name file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing '$3')"; fi
}
assert_not_contains() { # name file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 (found '$3')"; else ok "$1"; fi
}
assert_file() { # name path
  if [ -e "$2" ]; then ok "$1"; else bad "$1 (no such file $2)"; fi
}
assert_no_file() { # name path
  if [ -e "$2" ]; then bad "$1 (unexpectedly exists: $2)"; else ok "$1"; fi
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ---------------------------------------------------------------- extraction
step_script() { # step name -> its run: script on stdout
  ruby -ryaml -e '
    w = YAML.load_file(ARGV[0])
    s = w["jobs"]["build-and-deploy"]["steps"].find { |x| x["name"] == ARGV[1] }
    abort("no step named #{ARGV[1].inspect}") unless s
    puts s["run"]
  ' "$WF" "$1"
}

# ---------------------------------------------------------------- stubs
make_stubs() { # dir
  local d="$1"
  mkdir -p "$d"

  # timeout / sleep: no real waiting; the gate loop is iteration-bounded so a
  # no-op sleep cannot make it spin forever.
  cat > "$d/timeout" <<'E'
#!/bin/sh
shift
exec "$@"
E
  cat > "$d/sleep" <<'E'
#!/bin/sh
echo "$*" >> "${ST:-/dev/null}/sleep.log" 2>/dev/null
exit 0
E

  # flock shim for hosts without util-linux (macOS). Same CLI subset the
  # workflow uses: flock -w SECS -E CODE FILE CMD...
  cat > "$d/flock-shim" <<'E'
#!/usr/bin/env python3
import fcntl, os, sys, time
a = sys.argv[1:]
wait, ecode = None, 1
while a and a[0].startswith("-"):
    if a[0] == "-w": wait = float(a[1]); a = a[2:]
    elif a[0] == "-E": ecode = int(a[1]); a = a[2:]
    else: a = a[1:]
path, cmd = a[0], a[1:]
fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
end = None if wait is None else time.time() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except OSError:
        if end is not None and time.time() >= end: sys.exit(ecode)
        time.sleep(0.05)
os.set_inheritable(fd, True)  # the lock lives on the open file; it must survive exec
os.execvp(cmd[0], cmd)
E
  chmod +x "$d/flock-shim"
  if command -v flock >/dev/null 2>&1; then
    ln -sf "$(command -v flock)" "$d/flock"
  else
    ln -sf "$d/flock-shim" "$d/flock"
  fi

  cat > "$d/curl" <<'E'
#!/bin/bash
# prints the next status from $CURL_CODES (comma list); last one repeats
codes="${CURL_CODES:-200}"
f="$ST/curl.n"; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n + 1)) > "$f"
IFS=, read -ra arr <<<"$codes"
i=$n; [ "$i" -lt "${#arr[@]}" ] || i=$((${#arr[@]} - 1))
echo "curl $*" >> "$ST/curl.log"
printf '%s' "${arr[$i]}"
E

  cat > "$d/aws" <<'E'
#!/bin/bash
echo "aws $*" >> "$ST/aws.log"
case "$1 $2" in
  "ecr get-login-password") echo "FAKE-ECR-PASSWORD"; exit 0 ;;
  "ssm send-command")
    # keep the --parameters value for the payload tests
    while [ $# -gt 0 ]; do
      if [ "$1" = "--parameters" ]; then printf '%s' "$2" > "$ST/params.json"; fi
      shift
    done
    echo "cmd-0001"; exit 0 ;;
  "ssm get-command-invocation")
    printf '{"Status":"%s","ResponseCode":%s,"StandardOutputContent":"%s","StandardErrorContent":""}\n' \
      "${INVOCATION_STATUS:-Success}" "${INVOCATION_RC:-0}" "${INVOCATION_OUT:-box output}"
    exit 0 ;;
  "ec2 describe-instances")
    if [ -n "${DESCRIBE_ERR:-}" ]; then echo "$DESCRIBE_ERR" >&2; exit 254; fi
    printf '%s\n' "${DESCRIBE_OUT:-}"; exit 0 ;;
  "ecr batch-get-image")
    args="$*"
    case "$args" in
      *imageTag=latest*)
        # current :latest digest; after a put-image it is what was put
        if [ -f "$ST/ecr.put" ]; then cat "$ST/ecr.put"; else printf '%s\n' "${ECR_LATEST_DIGEST:-None}"; fi
        exit 0 ;;
      *imageDigest=*)
        if [[ "$args" == *imageManifest* ]]; then
          printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}\n'
        fi
        exit 0 ;;
    esac ;;
  "ecr put-image")
    echo "put-image $*" >> "$ST/ecr.puts"
    if [ -n "${PUT_FAIL:-}" ]; then echo "An error occurred (AccessDeniedException) when calling PutImage" >&2; exit 254; fi
    echo "${EXPECT_DIGEST_FOR_PUT:-}" > "$ST/ecr.put"; exit 0 ;;
esac
echo "UNSTUBBED aws $*" >&2; exit 99
E

  cat > "$d/docker" <<'E'
#!/bin/bash
# Stateful docker stub. State under $ST. Only the calls the payload makes.
echo "docker $*" >> "$ST/docker.log"
c="$ST/containers"
img_of() { # ref-or-id -> image id
  local x="$1"
  case "$x" in
    sha256:id-*) echo "$x" ;;
    *@sha256:*) cat "$ST/digest2id/${x##*@}" 2>/dev/null ;;
    *) cat "$ST/tag2id/$(echo "$x" | tr '/:' '__')" 2>/dev/null ;;
  esac
}
pop() { # file -> first line; drop it if more remain
  local f="$1" first
  first=$(head -n1 "$f"); if [ "$(wc -l < "$f")" -gt 1 ]; then tail -n +2 "$f" > "$f.n"; mv "$f.n" "$f"; fi
  printf '%s' "$first"
}
case "$1" in
  inspect)
    fmt=""; name=""
    shift
    while [ $# -gt 0 ]; do case "$1" in -f) fmt="$2"; shift 2 ;; *) name="$1"; shift ;; esac; done
    [ -d "$c/$name" ] || { echo "Error: No such object: $name" >&2; exit 1; }
    case "$fmt" in
      *State.Status*)
        printf '%s %s %s %s %s\n' "$(cat "$c/$name/status")" "$(cat "$c/$name/restarting")" \
          "$(pop "$c/$name/rc_seq")" "$(pop "$c/$name/health_seq")" "$(cat "$c/$name/imgid")" ;;
      *Config.Image*) printf '%s %s\n' "$(cat "$c/$name/ref")" "$(cat "$c/$name/imgid")" ;;
      *Config.Env*) cat "$c/$name/env" ;;
      *) echo "UNSTUBBED inspect fmt $fmt" >&2; exit 99 ;;
    esac ;;
  image)
    [ "$2" = inspect ] || { echo "UNSTUBBED docker image $2" >&2; exit 99; }
    shift 2; fmt=""; x=""
    while [ $# -gt 0 ]; do case "$1" in -f) fmt="$2"; shift 2 ;; *) x="$1"; shift ;; esac; done
    id=$(img_of "$x"); [ -n "$id" ] || { echo "Error: No such image: $x" >&2; exit 1; }
    case "$fmt" in
      *RepoDigests*) cat "$ST/id2repodigest/$id" ;;
      *Config.Env*) cat "$ST/id2env/$id" 2>/dev/null || true ;;
      *) echo "UNSTUBBED image inspect fmt $fmt" >&2; exit 99 ;;
    esac ;;
  pull)
    [ -z "${PULL_FAIL:-}" ] || { echo "pull failed" >&2; exit 1; }
    id=$(img_of "$2"); [ -n "$id" ] || { echo "manifest unknown: $2" >&2; exit 1; }
    echo "pulled $2" ;;
  login) cat >/dev/null; echo "Login Succeeded" ;;
  run)
    echo "$*" > "$ST/run.args"
    envf=""; prev=""
    for a in "$@"; do [ "$prev" = "--env-file" ] && envf="$a"; prev="$a"; done
    if [ -n "$envf" ] && [ -f "$envf" ]; then
      echo "$envf" > "$ST/run.envpath"
      (stat -c %a "$envf" 2>/dev/null || stat -f %Lp "$envf") > "$ST/run.mode"
      cp "$envf" "$ST/run.envcopy"
    fi
    echo "calls: $(cat "$ST/redeploy.calls" 2>/dev/null | wc -l | tr -d ' ')" > "$ST/run.redeploys_before"
    case "$*" in
      *"migrate status"*) echo "Following migration have not yet been applied: 20260101_x"; exit "${MIGRATE_STATUS_RC:-1}" ;;
    esac
    echo "Datasource: ${MIGRATE_LEAK:-ok}"
    exit "${MIGRATE_RC:-0}" ;;
  *) echo "UNSTUBBED docker $*" >&2; exit 99 ;;
esac
E

  chmod +x "$d"/*
}

# Build the box fixture. REPO is the api image repo.
REPO="772316781095.dkr.ecr.eu-west-1.amazonaws.com/storytime/api"
NEWSHA="0123456789abcdef0123456789abcdef01234567"
NEWDIGEST="sha256:$(printf 'a%.0s' $(seq 1 64))"
OLDDIGEST="sha256:$(printf 'b%.0s' $(seq 1 64))"

new_box() { # sandbox dir
  SB="$1"; ST="$SB/st"; export SB ST
  rm -rf "$SB"; mkdir -p "$SB/bin" "$ST/containers/api" "$ST/tag2id" "$ST/digest2id" \
    "$ST/id2repodigest" "$ST/id2env" "$SB/run" "$SB/deployed"
  make_stubs "$SB/bin"

  # images: old (what runs now, tagged :latest) and new (the sha tag)
  echo "sha256:id-old" > "$ST/tag2id/$(echo "$REPO:latest" | tr '/:' '__')"
  echo "sha256:id-new" > "$ST/tag2id/$(echo "$REPO:$NEWSHA" | tr '/:' '__')"
  echo "sha256:id-old" > "$ST/digest2id/$OLDDIGEST"
  echo "sha256:id-new" > "$ST/digest2id/$NEWDIGEST"
  echo "$REPO@$OLDDIGEST" > "$ST/id2repodigest/sha256:id-old"
  echo "$REPO@$NEWDIGEST" > "$ST/id2repodigest/sha256:id-new"
  printf 'PATH=/usr/bin\nNODE_VERSION=22\n' > "$ST/id2env/sha256:id-old"
  printf 'PATH=/usr/bin\nNODE_VERSION=22\n' > "$ST/id2env/sha256:id-new"

  # the running api container
  c="$ST/containers/api"
  echo "$REPO:latest" > "$c/ref"; echo sha256:id-old > "$c/imgid"
  echo running > "$c/status"; echo false > "$c/restarting"
  echo 0 > "$c/rc_seq"; echo healthy > "$c/health_seq"
  printf 'PATH=/usr/bin\nNODE_VERSION=22\nDATABASE_URL=postgres://u:hunter2secret@db:5432/x\nJWT_SECRET=supersecretvalue\n' > "$c/env"

  # a redeploy.sh stand-in: supports `<service> <tag>` (mentions TAG_OVERRIDE
  # so the payload's capability probe passes) and lists run_service lines.
  cat > "$SB/redeploy.sh" <<'E'
#!/bin/bash
# stub of redeploy.sh -- honours TAG_OVERRIDE="${2:-}" like the real one
run_service() { :; }
run_service "api" "api" "772316781095.dkr.ecr.eu-west-1.amazonaws.com/storytime/api:latest" "3000" "3000" "512"
svc="$1"; tag="${2:-latest}"
echo "$svc $tag" >> "$ST/redeploy.calls"
c="$ST/containers/api"
if [ "$tag" = "$NEWSHA" ]; then
  [ -z "${NEW_SWAP_FAIL:-}" ] || { echo "swap failed" >&2; echo exited > "$c/status"; exit 1; }
  echo "$REPO:$tag" > "$c/ref"; echo sha256:id-new > "$c/imgid"
  printf '%s\n' ${NEW_HEALTH:-starting healthy} > "$c/health_seq"
  printf '%s\n' ${NEW_RC:-0} > "$c/rc_seq"
else
  [ -z "${ROLLBACK_FAIL:-}" ] || { echo "rollback swap failed" >&2; echo exited > "$c/status"; exit 1; }
  echo "$REPO:$tag" > "$c/ref"; echo sha256:id-old > "$c/imgid"
  printf '%s\n' ${OLD_HEALTH:-healthy} > "$c/health_seq"; echo 0 > "$c/rc_seq"
fi
[ "$tag" = "$NEWSHA" ] && [ -n "${NEW_SWAP_FAIL:-}" ] || echo running > "$c/status"
echo "started api"
E
  chmod +x "$SB/redeploy.sh"
  export REPO NEWSHA
}

# Assemble the payload with the workflow's real step + jq, then run it as the
# box would. Prints nothing; leaves $SB/out.txt and $SB/rc.
run_payload() { # [VAR=val ...] extra env for the *step* and the payload
  (
    cd "$SB" || exit 1
    export PATH="$SB/bin:$PATH" ST AWS_REGION=eu-west-1 INSTANCE_ID=i-0123456789abcdef0 \
      SERVICE=api ENVIRONMENT=prod IMAGE_SHA="$NEWSHA" EXPECT_DIGEST="$NEWDIGEST" \
      REPO_URI="$REPO" POLL_TIMEOUT=2400 RUN_MIGRATIONS=false DRY_RUN=false \
      HEALTH_TIMEOUT=60 STABLE_SAMPLES=3 GATE_SMOKE_URL="" GATE_SMOKE_EXPECT="200,204,401,403" \
      GITHUB_OUTPUT="$SB/gh_output" NEWSHA REPO
    for kv in "$@"; do export "${kv?}"; done
    # The step writes fixed /tmp paths; keep them inside this run's sandbox so
    # concurrent runs cannot collide and nothing outlives the harness.
    step_script "Deploy on the instance" | sed "s#/tmp/#$SB/#g" > "$SB/step.sh"
    bash "$SB/step.sh" > "$SB/step.out" 2>&1
    echo $? > "$SB/step.rc"
  )
  jq -r '.commands | join("\n")' "$ST/params.json" > "$SB/payload.sh"
  (
    cd "$SB" || exit 1
    export PATH="$SB/bin:$PATH" ST NEWSHA REPO
    for kv in "$@"; do export "${kv?}"; done
    export STORYTIME_REDEPLOY="$SB/redeploy.sh" STORYTIME_STATE_DIR="$SB/deployed" \
      STORYTIME_ENV_ROOT="$SB/run" STORYTIME_LOCK="$SB/lock" STORYTIME_GATE_INTERVAL=1 \
      STORYTIME_LOCK_WAIT="${LOCK_WAIT:-5}"
    "$PAYLOAD_SH" "$SB/payload.sh" > "$SB/out.txt" 2>&1
    echo $? > "$SB/rc"
  )
}

# ================================================================ tests
CURRENT=""
begin() { CURRENT="$1"; printf '\n== %s\n' "$1"; }

if ! command -v ruby >/dev/null || ! command -v jq >/dev/null; then
  echo "need ruby and jq"; exit 2
fi
export -f step_script
export WF

# ---- 0. the payload assembles and parses under the target shell
begin "payload assembly"
new_box "$TMP/t0"
run_payload
assert_eq "step built SSM params" 0 "$(cat "$SB/step.rc")"
assert_eq "payload parses (sh -n)" 0 "$("$PAYLOAD_SH" -n "$SB/payload.sh" >/dev/null 2>&1; echo $?)"
assert_contains "payload takes the flock" "$SB/payload.sh" 'flock -w'
assert_contains "payload uses the shared lock path" "$SB/payload.sh" '/run/lock/storytime-deploy.lock'
assert_contains "executionTimeout covers lock wait" "$ST/params.json" 'executionTimeout'

# ---- 1. success path
begin "success path"
new_box "$TMP/t1"
run_payload
assert_eq "exit 0" 0 "$(cat "$SB/rc")"
assert_eq "exactly one redeploy" 1 "$(lines "$ST/redeploy.calls")"
assert_eq "single-service form with the immutable tag" "api $NEWSHA" "$(head -n1 "$ST/redeploy.calls")"
assert_not_contains "never a box-wide reconcile" "$ST/docker.log" 'systemctl'
assert_contains "state file records previous ref" "$SB/deployed/api" "previous=$REPO:latest"
assert_contains "state file records result" "$SB/deployed/api" "result=ok"
assert_contains "verdict printed" "$SB/out.txt" "DEPLOY OK"
assert_not_contains "no image prune from payload" "$ST/docker.log" 'prune'
assert_no_file "no migration container when run_migrations=false" "$ST/run.args"

# ---- 2. unhealthy -> automatic rollback
begin "unhealthy image rolls back"
new_box "$TMP/t2"
run_payload NEW_HEALTH="starting unhealthy"
assert_eq "exit 1 (failed, rolled back)" 1 "$(cat "$SB/rc")"
assert_eq "redeploy called twice" 2 "$(lines "$ST/redeploy.calls")"
assert_eq "second call restores the previous tag" "api latest" "$(sed -n 2p "$ST/redeploy.calls")"
assert_contains "ROLLED BACK printed" "$SB/out.txt" "ROLLED BACK"
assert_contains "state file says rolled-back" "$SB/deployed/api" "result=rolled-back"
assert_eq "container is back on the old image" "sha256:id-old" "$(cat "$ST/containers/api/imgid")"

begin "restart-looping container rolls back even if health says healthy"
new_box "$TMP/t2b"
run_payload NEW_HEALTH="healthy" NEW_RC="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60"
assert_eq "exit 1" 1 "$(cat "$SB/rc")"
assert_contains "rolled back" "$SB/out.txt" "ROLLED BACK"

begin "swap itself failing rolls back"
new_box "$TMP/t2c"
run_payload NEW_SWAP_FAIL=1
assert_eq "exit 1" 1 "$(cat "$SB/rc")"
assert_eq "redeploy called twice" 2 "$(lines "$ST/redeploy.calls")"
assert_contains "rolled back" "$SB/out.txt" "ROLLED BACK"

begin "rollback that cannot recover exits 2 (page someone)"
new_box "$TMP/t2d"
run_payload NEW_HEALTH="unhealthy" ROLLBACK_FAIL=1
assert_eq "exit 2" 2 "$(cat "$SB/rc")"
assert_contains "ROLLBACK FAILED printed" "$SB/out.txt" "ROLLBACK FAILED"
assert_contains "state file says rollback-failed" "$SB/deployed/api" "result=rollback-failed"

# ---- 3. migrations
begin "migration success then swap"
new_box "$TMP/t3a"
run_payload RUN_MIGRATIONS=true MIGRATE_LEAK=postgres://u:hunter2secret@db:5432/x
assert_eq "exit 0" 0 "$(cat "$SB/rc")"
assert_contains "ran on the storytime network" "$ST/run.args" "--network storytime"
assert_contains "uses an env-file" "$ST/run.args" "--env-file"
assert_contains "runs prisma migrate deploy" "$ST/run.args" "node_modules/.bin/prisma migrate deploy"
assert_contains "runs the NEW image by digest" "$ST/run.args" "$REPO@$NEWDIGEST"
assert_eq "env-file was mode 600" 600 "$(cat "$ST/run.mode")"
assert_contains "env-file carried the running api's secret" "$ST/run.envcopy" "JWT_SECRET=supersecretvalue"
assert_not_contains "image-baked PATH not forwarded" "$ST/run.envcopy" "PATH=/usr/bin"
assert_no_file "temp env-file deleted" "$(cat "$ST/run.envpath")"
assert_not_contains "secret value never printed" "$SB/out.txt" "hunter2secret"
assert_not_contains "secret value never printed (jwt)" "$SB/out.txt" "supersecretvalue"
assert_not_contains "never docker exec" "$ST/docker.log" "docker exec"
assert_eq "swap happened after migration" 1 "$(lines "$ST/redeploy.calls")"

begin "migration failure aborts before any swap"
new_box "$TMP/t3b"
run_payload RUN_MIGRATIONS=true MIGRATE_RC=1 MIGRATE_LEAK=postgres://u:hunter2secret@db:5432/x
assert_eq "exit 3 (aborted, nothing replaced)" 3 "$(cat "$SB/rc")"
assert_no_file "redeploy.sh never called" "$ST/redeploy.calls"
assert_eq "old container untouched" "sha256:id-old" "$(cat "$ST/containers/api/imgid")"
assert_no_file "temp env-file deleted on failure" "$(cat "$ST/run.envpath")"
assert_not_contains "secret masked in migration output" "$SB/out.txt" "hunter2secret"
assert_contains "operator told old containers keep running" "$SB/out.txt" "ABORTED"

# ---- 4. dry run
begin "dry run"
new_box "$TMP/t4"
run_payload DRY_RUN=true RUN_MIGRATIONS=true
assert_eq "exit 0" 0 "$(cat "$SB/rc")"
assert_no_file "no container replaced" "$ST/redeploy.calls"
assert_contains "migrate STATUS only" "$ST/run.args" "migrate status"
assert_not_contains "never migrate deploy" "$ST/run.args" "migrate deploy"
assert_contains "dry run verdict" "$SB/out.txt" "DRY RUN"

# ---- 5. gate smoke
begin "gate smoke failure rolls back"
new_box "$TMP/t5a"
run_payload GATE_SMOKE_URL=https://api.example.test/api/v1/health CURL_CODES=500
assert_eq "exit 1" 1 "$(cat "$SB/rc")"
assert_contains "rolled back" "$SB/out.txt" "ROLLED BACK"
assert_contains "curl went through the local proxy via --resolve" "$ST/curl.log" "--resolve api.example.test:443:127.0.0.1"

begin "gate smoke 401 accepted"
new_box "$TMP/t5b"
run_payload GATE_SMOKE_URL=https://api.example.test/x CURL_CODES=401
assert_eq "exit 0" 0 "$(cat "$SB/rc")"

# ---- 6. preflight
begin "preflight aborts"
new_box "$TMP/t6a"
sed -i.bak 's/TAG_OVERRIDE/X/' "$SB/redeploy.sh"
run_payload
assert_eq "old redeploy.sh without tag form -> exit 3" 3 "$(cat "$SB/rc")"
assert_no_file "nothing swapped" "$ST/redeploy.calls"

new_box "$TMP/t6b"
# the :sha tag resolves to a DIFFERENT image than the digest the build reported
echo "sha256:id-old" > "$ST/tag2id/$(echo "$REPO:$NEWSHA" | tr '/:' '__')"
run_payload
assert_eq "tag/digest mismatch -> exit 3" 3 "$(cat "$SB/rc")"
assert_no_file "nothing swapped" "$ST/redeploy.calls"

new_box "$TMP/t6c"
run_payload PULL_FAIL=1
assert_eq "pull failure -> exit 3" 3 "$(cat "$SB/rc")"
assert_no_file "nothing swapped" "$ST/redeploy.calls"

new_box "$TMP/t6d"
echo "$REPO@$OLDDIGEST" > "$ST/containers/api/ref"
run_payload
assert_eq "previous ref not rollback-able (digest form) -> exit 3" 3 "$(cat "$SB/rc")"
assert_no_file "nothing swapped" "$ST/redeploy.calls"

# ---- 7. lock
begin "lock contention"
new_box "$TMP/t7a"
# hold the deploy lock for 4s; a deploy with a 1s wait must give up, untouched
( "$SB/bin/flock" "$SB/lock" /bin/sleep 4 ) &
holder=$!
sleep 0.5
run_payload LOCK_WAIT=1
assert_eq "exit 75 when the lock is not obtained" 75 "$(cat "$SB/rc")"
assert_no_file "nothing swapped while locked" "$ST/redeploy.calls"
wait "$holder"

new_box "$TMP/t7b"
( "$SB/bin/flock" "$SB/lock" /bin/sleep 3 ) &
holder=$!
sleep 0.5
start=$(date +%s)
run_payload LOCK_WAIT=20
elapsed=$(( $(date +%s) - start ))
assert_eq "queued deploy ran after the holder released (exit 0)" 0 "$(cat "$SB/rc")"
if [ "$elapsed" -ge 2 ]; then ok "it actually waited (${elapsed}s)"; else bad "did not wait for the lock (${elapsed}s)"; fi
assert_eq "swap done once" 1 "$(lines "$ST/redeploy.calls")"
wait "$holder"

# ---- 8. runner-side: instance lookup
begin "instance lookup"
lookup() { # DESCRIBE_OUT/ERR via env; prints rc, leaves $SB/lk.out
  (
    export PATH="$SB/bin:$PATH" ST GITHUB_OUTPUT="$SB/gh_output" AWS_REGION=eu-west-1 \
      ENVIRONMENT="${ENVIRONMENT:-prod}" INSTANCE_ID_IN="${INSTANCE_ID_IN:-}"
    step_script "Resolve target instance" > "$SB/lk.sh"
    bash "$SB/lk.sh" > "$SB/lk.out" 2>&1; echo $?
  )
}
new_box "$TMP/t8"
: > "$SB/gh_output"
rc=$(DESCRIBE_OUT="i-0d904f863b0161bcc" lookup)
assert_eq "one match -> ok" 0 "$rc"
assert_contains "emitted the id" "$SB/gh_output" "id=i-0d904f863b0161bcc"
assert_contains "filters on Stack tag" "$ST/aws.log" "Name=tag:Stack,Values=storytime-prod"
assert_contains "filters on Name tag" "$ST/aws.log" "Name=tag:Name,Values=storytime-prod-app"
assert_contains "filters on running" "$ST/aws.log" "Name=instance-state-name,Values=running"

: > "$SB/gh_output"
rc=$(DESCRIBE_OUT="" lookup)
assert_eq "zero matches -> fail" 1 "$rc"
assert_contains "says zero" "$SB/lk.out" "found 0"
rc=$(DESCRIBE_OUT="i-0d904f863b0161bcc	i-0aaaaaaaaaaaaaaaa" lookup)
assert_eq "two matches -> fail" 1 "$rc"
assert_contains "says two" "$SB/lk.out" "found 2"
rc=$(DESCRIBE_ERR="An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation" lookup)
assert_eq "role lacks ec2:DescribeInstances -> fail" 1 "$rc"
assert_contains "error is actionable" "$SB/lk.out" "instance_id"
assert_contains "names the IAM action" "$SB/lk.out" "ec2:DescribeInstances"

: > "$SB/gh_output"; : > "$ST/aws.log"
rc=$(INSTANCE_ID_IN="i-00000000000000001" lookup)
assert_eq "explicit instance_id still honoured" 0 "$rc"
assert_contains "uses the override" "$SB/gh_output" "id=i-00000000000000001"
assert_not_contains "no EC2 call when overridden" "$ST/aws.log" "describe-instances"
rc=$(ENVIRONMENT=staging DESCRIBE_OUT="i-0d904f863b0161bcc" lookup)
assert_eq "auto-lookup refused for non-prod" 1 "$rc"

# ---- 9. runner-side: promote :latest
begin "promote latest"
promote() {
  (
    export PATH="$SB/bin:$PATH" ST AWS_REGION=eu-west-1 GITHUB_OUTPUT="$SB/gh_output" \
      REPOSITORY="storytime/api" EXPECT_DIGEST="$NEWDIGEST" IMAGE_SHA="$NEWSHA"
    step_script "Promote latest" > "$SB/pr.sh"
    bash "$SB/pr.sh" > "$SB/pr.out" 2>&1; echo $?
  )
}
new_box "$TMP/t9a"
rc=$(ECR_LATEST_DIGEST="$OLDDIGEST" EXPECT_DIGEST_FOR_PUT="$NEWDIGEST" promote)
assert_eq "moves latest to the verified digest" 0 "$rc"
assert_eq "one put-image" 1 "$(lines "$ST/ecr.puts")"
assert_contains "put-image targets :latest" "$ST/ecr.puts" "--image-tag latest"
new_box "$TMP/t9b"
rc=$(ECR_LATEST_DIGEST="$NEWDIGEST" promote)
assert_eq "already latest -> ok, no write" 0 "$rc"
assert_no_file "no put-image" "$ST/ecr.puts"
new_box "$TMP/t9c"
rc=$(ECR_LATEST_DIGEST="$OLDDIGEST" PUT_FAIL=1 promote)
assert_eq "put-image failure -> job fails" 1 "$rc"

# ---- 10. runner-side: failure annotation from the box's exit code
begin "runner maps the box exit code"
for pair in "75:lock" "2:ROLLBACK FAILED" "1:ROLLED BACK" "3:aborted before"; do
  code="${pair%%:*}"; needle="${pair#*:}"
  new_box "$TMP/t10-$code"
  run_payload INVOCATION_STATUS=Failed INVOCATION_RC="$code"
  assert_eq "step fails for box exit $code" 1 "$(cat "$SB/step.rc")"
  assert_contains "annotation mentions '$needle' for $code" "$SB/step.out" "$needle"
done

# ---- 11. validation of the new inputs
begin "input validation"
validate() { # env assignments -> rc
  (
    export SERVICE=api ENVIRONMENT=prod ROLE_ARN=arn:aws:iam::772316781095:role/x \
      INSTANCE_ID="" AWS_REGION_IN=eu-west-1 RECONCILE_TIMEOUT=2400 ECR_PREFIX=storytime \
      DOCKERFILE=Dockerfile BUILD_CONTEXT=. BUILD_ARGS="" RUN_MIGRATIONS=false DRY_RUN=false \
      HEALTH_TIMEOUT=300 STABLE_SAMPLES=6 GATE_SMOKE_URL="" GATE_SMOKE_EXPECT="200,204,401,403"
    for kv in "$@"; do export "${kv?}"; done
    step_script "Validate inputs" > "$TMP/val.sh"
    bash "$TMP/val.sh" > "$TMP/val.out" 2>&1; echo $?
  )
}
assert_eq "defaults valid, instance_id omitted" 0 "$(validate)"
assert_eq "explicit instance_id valid" 0 "$(validate INSTANCE_ID=i-0123456789abcdef0)"
assert_eq "bad instance_id rejected" 1 "$(validate INSTANCE_ID=nope)"
assert_eq "run_migrations only for api" 1 "$(validate SERVICE=web RUN_MIGRATIONS=true BUILD_ARGS=NEXT_PUBLIC_API_URL=https://x)"
assert_eq "health timeout too low" 1 "$(validate HEALTH_TIMEOUT=5)"
assert_eq "timeout without a warm-up sample rejected" 1 "$(validate HEALTH_TIMEOUT=60 STABLE_SAMPLES=6)"
assert_eq "timeout with exactly one warm-up sample valid" 0 "$(validate HEALTH_TIMEOUT=70 STABLE_SAMPLES=6)"
assert_eq "non-https gate url rejected" 1 "$(validate GATE_SMOKE_URL=http://x.test/)"
assert_eq "bad expect list rejected" 1 "$(validate GATE_SMOKE_EXPECT='200;rm')"
assert_eq "legacy 2400 reconcile timeout still valid" 0 "$(validate RECONCILE_TIMEOUT=2400)"

# ================================================================ summary
printf '\n----\n%d passed, %d failed (payload shell: %s)\n' "$PASS" "$FAIL" "$PAYLOAD_SH"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'; printf '  %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
