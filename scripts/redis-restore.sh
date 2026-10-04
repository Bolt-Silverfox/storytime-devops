#!/usr/bin/env bash
# redis-restore.sh — put a Redis volume archive back onto the box.
#
# WHY THIS EXISTS
# ---------------
# Redis is a CONTAINER on the app instance, not ElastiCache, so its dataset lives
# in a docker volume on the root EBS volume. `user_data_replace_on_change = true`
# means any bootstrap change REPLACES the instance, and the volume goes with it.
# This is the other half of scripts/redis-backup.sh: without it the backup is a
# file nobody knows how to use.
#
# THE TRAP THIS AVOIDS
# --------------------
# The container runs `redis-server --appendonly yes`. On start Redis loads
# `appendonlydir/` and IGNORES dump.rdb. Restoring only the RDB therefore gives a
# silently EMPTY Redis — no error, no warning, just no data. The archive carries
# both, and this script restores the whole directory. Verified on 2026-10-04: the
# restored container logged `DB loaded from base file appendonly.aof.3.base.rdb`.
#
# THIS IS DESTRUCTIVE. It stops Redis and replaces the volume contents. Anything
# written since the archive was taken is lost, which is why --dry-run shows you
# the current key count and the archive first.
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
BUCKET="${BUCKET:-storytime-prod-backups}"
STACK="${STACK:-storytime-prod}"
PREFIX="redis"
KEY=""
DRY_RUN=0

usage() {
  cat >&2 <<USAGE
usage: $0 [--key <s3 key>] [--dry-run]

  --key      the archive to restore, e.g. redis/storytime-prod/2026/10/04/....tar.gz
             omitted: the newest archive under $PREFIX/$STACK/
  --dry-run  report what would happen and change nothing
USAGE
  exit 64
}
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:?--key needs a value}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done

fail() { echo "REDIS RESTORE FAILED: $*" >&2; exit 1; }

# By tag, not by instance id: the box is replaceable, and restoring is exactly the
# moment a pinned id would be wrong.
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Stack,Values=$STACK" "Name=tag:Name,Values=$STACK-app" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text) || fail "could not query instances"
[ -n "$INSTANCE" ] || fail "no running instance tagged Stack=$STACK Name=$STACK-app"
[ "$(wc -w <<<"$INSTANCE")" -eq 1 ] || fail "more than one instance matched: $INSTANCE"

if [ -z "$KEY" ]; then
  # List and sort in two steps. `--query 'sort_by(Contents,...)'` makes the CLI
  # exit NON-ZERO when the prefix is empty, because jmespath cannot sort null —
  # so a one-liner reports "could not list" for a bucket it listed perfectly well.
  # An empty prefix is a normal state (no backup taken yet) and deserves its own
  # message.
  LISTING=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/$STACK/" \
    --query 'Contents[].[LastModified,Key]' --output text 2>/dev/null) \
    || fail "could not list s3://$BUCKET/$PREFIX/$STACK/ — check credentials and the bucket name"
  if [ -z "$LISTING" ] || [ "$LISTING" = "None" ]; then
    fail "no archive exists under s3://$BUCKET/$PREFIX/$STACK/ — run scripts/redis-backup.sh first"
  fi
  KEY=$(sort <<<"$LISTING" | tail -1 | awk '{print $2}')
  [ -n "$KEY" ] || fail "could not determine the newest archive from the listing"
fi
# VALIDATE BEFORE INTERPOLATING. $KEY is substituted into single-quoted strings
# inside the remote command (`aws s3 cp 's3://...'`, `logger '...'`). A single
# quote in the key would close that quoting and the remainder would run as shell
# on the production box. This check covers BOTH sources — an operator --key and a
# key read back from S3 — which is why it sits after the selection, not inside it.
[[ "$KEY" =~ ^redis/[A-Za-z0-9/_.-]+\.tar\.gz$ ]] \
  || fail "refusing an archive key that is not ^redis/[A-Za-z0-9/_.-]+\.tar\.gz\$ : $KEY"

echo "instance: $INSTANCE"
echo "archive:  s3://$BUCKET/$KEY"

run_remote() {
  local script="$1" req cid status
  req=$(mktemp /var/tmp/ssm-req.XXXXXX.json)
  SCRIPT="$script" python3 - "$INSTANCE" "$req" <<'PYEOF'
import json, os, sys
json.dump({
    "InstanceIds": [sys.argv[1]],
    "DocumentName": "AWS-RunShellScript",
    "Comment": "redis restore from s3",
    "Parameters": {"commands": [os.environ["SCRIPT"]]},
}, open(sys.argv[2], "w"))
PYEOF
  cid=$(aws ssm send-command --cli-input-json "file://$req" --query 'Command.CommandId' --output text) \
    || { rm -f "$req"; fail "send-command failed"; }
  rm -f "$req"
  for _ in $(seq 1 60); do
    sleep 5
    status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Success|Failed|Cancelled|TimedOut) break;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE" \
    --query StandardOutputContent --output text 2>/dev/null | sed 's/^/  /'
  if [ "$status" != "Success" ]; then
    aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE" \
      --query StandardErrorContent --output text 2>/dev/null | sed 's/^/  stderr: /'
    fail "remote step exited $status"
  fi
}

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY RUN — nothing will be changed."
  run_remote "set -euo pipefail
echo \"current live keys: \$(docker exec redis redis-cli DBSIZE | tr -d '\r')\"
aws s3 cp --region $REGION --only-show-errors 's3://$BUCKET/$KEY' /var/tmp/redis-restore.tar.gz
echo 'archive contents:'; tar -tzf /var/tmp/redis-restore.tar.gz | sed 's/^/  /'
rm -f /var/tmp/redis-restore.tar.gz
echo 'would: stop redis, replace the storytime-redis volume contents, start redis'"
  exit 0
fi

# A safety archive of the CURRENT dataset before overwriting it. Restoring the
# wrong archive is recoverable; restoring over an un-backed-up dataset is not.
#
# EVERYTHING AFTER THE SAFETY COPY IS ROLLED BACK ON FAILURE. The first version of
# this script had two outage paths: if tar -xzf failed after the volume had been
# cleared, set -e exited before docker start redis and left Redis stopped on an
# empty volume; and if docker start failed, or Redis never answered PING, nothing
# put the old dataset back. Both are now covered by an ERR trap armed only once the
# safety copy exists.
run_remote "set -euo pipefail
PRE=/var/tmp/redis-pre-restore.tar.gz

# Compact the AOF BEFORE the safety copy, for the same reason the backup does it:
# otherwise the rollback artefact is an un-rewritten AOF, i.e. the thing we would
# fall back to is weaker than the thing we are replacing.
docker exec redis redis-cli -e BGREWRITEAOF >/dev/null \\
  || { echo 'BGREWRITEAOF rejected — refusing to restore without a sound safety copy' >&2; exit 1; }
for i in \$(seq 1 120); do
  P=\$(docker exec redis redis-cli INFO persistence | tr -d '\\r')
  IN=\$(sed -n 's/^aof_rewrite_in_progress:\\(.*\\)\$/\\1/p' <<<\"\$P\")
  SCHED=\$(sed -n 's/^aof_rewrite_scheduled:\\(.*\\)\$/\\1/p' <<<\"\$P\")
  [ \"\$IN\" = '0' ] && [ \"\${SCHED:-0}\" = '0' ] && break
  sleep 1
done
# The flags going to 0 says the rewrite ENDED, not that it SUCCEEDED. On
# aof_last_bgrewrite_status=err the old AOF is still loadable, so the rollback
# copy is not worthless -- but it has no fresh base, and its live incremental
# file can be captured mid-write by the tar below, leaving the copy missing its
# tail. A rollback artefact is the one thing that must not be approximate, so
# this refuses rather than proceeding. redis-backup.sh already asserted it; the
# two had drifted.
STATUS=\$(docker exec redis redis-cli INFO persistence | tr -d '\\r' | sed -n 's/^aof_last_bgrewrite_status:\\(.*\\)\$/\\1/p')
[ \"\$STATUS\" = 'ok' ] \\
  || { echo \"aof_last_bgrewrite_status=\$STATUS after the rewrite -- refusing to restore without a sound safety copy\" >&2; exit 1; }
BEFORE=\$(docker exec redis redis-cli DBSIZE | tr -d '\\r')
echo \"live keys before restore: \$BEFORE\"

docker run --rm -v storytime-redis:/d:ro -v /var/tmp:/out alpine \\
  tar -czf /out/redis-pre-restore.tar.gz -C /d . >/dev/null
echo \"pre-restore safety copy: \$PRE (\$(stat -c %s \$PRE) bytes)\"

rollback() {
  echo 'RESTORE FAILED — rolling back to the pre-restore dataset' >&2
  docker stop redis >/dev/null 2>&1 || true
  if docker run --rm -v storytime-redis:/d -v /var/tmp:/in alpine sh -c \\
       'rm -rf /d/* /d/..?* /d/.[!.]* 2>/dev/null; tar -xzf /in/redis-pre-restore.tar.gz -C /d' >/dev/null; then
    docker start redis >/dev/null 2>&1 \\
      && echo 'rollback ok: previous dataset restored and redis started' >&2 \\
      || echo 'ROLLBACK EXTRACTED BUT REDIS WOULD NOT START — manual attention needed' >&2
  else
    echo \"ROLLBACK FAILED — the volume may be empty. The safety copy is at \$PRE\" >&2
  fi
  logger -t storytime-redis-restore -p user.crit 'restore failed; rollback attempted'
  exit 1
}
# NOT ARMED YET. On AL2023 /bin/sh is Bash, so a failing top-level command fires
# the ERR trap before set -e exits — and arming it here meant a failed aws s3
# cp (a 403, a network blip) would run rollback, which stops Redis, clears the
# volume and re-extracts, all while nothing had been touched. A safety mechanism
# that breaks a healthy Redis on a benign download failure is worse than none.
# The trap goes on immediately before docker stop redis instead.
aws s3 cp --region $REGION --only-show-errors 's3://$BUCKET/$KEY' /var/tmp/redis-restore.tar.gz
# Fail before touching anything if the archive is not what we expect. A tar that
# unpacks without appendonlydir would leave Redis loading NOTHING, because the
# container runs with --appendonly yes and ignores dump.rdb.
tar -tzf /var/tmp/redis-restore.tar.gz | grep -q 'appendonlydir/' \\
  || { echo 'archive has no appendonlydir/ — refusing, Redis would start EMPTY' >&2; exit 1; }

# FROM HERE ON the volume is being replaced, so a failure must roll back.
trap rollback ERR

# Stop Redis before replacing the volume. Writing under a running server would
# leave it serving a dataset that no longer matches what is on disk.
docker stop redis >/dev/null
docker run --rm -v storytime-redis:/d -v /var/tmp:/in alpine sh -c \\
  'rm -rf /d/* /d/..?* /d/.[!.]* 2>/dev/null; tar -xzf /in/redis-restore.tar.gz -C /d' >/dev/null
docker start redis >/dev/null

# Readiness is checked, not assumed. The old loop could run out and fall through
# to a DBSIZE inside an echo, which hid the error and reported success.
READY=0
for i in \$(seq 1 30); do
  if docker exec redis redis-cli PING 2>/dev/null | grep -q PONG; then READY=1; break; fi
  sleep 1
done
# CALL rollback, do not exit 1. An explicit exit does NOT fire the ERR trap
# (verified), so exiting here would detect the failure and then skip the very
# recovery this trap exists for — leaving Redis down on a freshly replaced volume.
# That was the hole the readiness check was added to close, and the check alone
# did not close it.
[ \"\$READY\" = '1' ] || { echo 'redis did not answer PING after the restore' >&2; rollback; }

AFTER=\$(docker exec redis redis-cli DBSIZE | tr -d '\\r')
echo \"live keys after restore: \$AFTER (was \$BEFORE)\"
# || true because this is DIAGNOSTIC ONLY. grep exits 1 when it matches
# nothing — a noisier log, a Redis version that words it differently — and with
# the trap still armed that non-zero would run rollback and destroy the dataset
# that had just been restored and verified. An informational line must not be
# able to fail the script.
docker logs --tail 40 redis 2>&1 | grep -iE 'DB loaded|Ready to accept' | sed 's/^/  /' || true

trap - ERR
rm -f /var/tmp/redis-restore.tar.gz
logger -t storytime-redis-restore -p user.notice 'restored $KEY'"

echo "done. The pre-restore safety copy is at /var/tmp/redis-pre-restore.tar.gz on the box"
echo "and is NOT in S3 — copy it off if you may need to roll back."
