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
run_remote "set -euo pipefail
echo \"live keys before restore: \$(docker exec redis redis-cli DBSIZE | tr -d '\r')\"
docker run --rm -v storytime-redis:/d:ro -v /var/tmp:/out alpine \
  tar -czf /out/redis-pre-restore.tar.gz -C /d . >/dev/null
echo \"pre-restore safety copy: /var/tmp/redis-pre-restore.tar.gz (\$(stat -c %s /var/tmp/redis-pre-restore.tar.gz) bytes)\"

aws s3 cp --region $REGION --only-show-errors 's3://$BUCKET/$KEY' /var/tmp/redis-restore.tar.gz
# Fail before touching anything if the archive is not what we expect. A tar that
# unpacks without appendonlydir would leave Redis loading nothing.
tar -tzf /var/tmp/redis-restore.tar.gz | grep -q 'appendonlydir/' \
  || { echo 'archive has no appendonlydir/ — refusing to restore, Redis would start EMPTY' >&2; exit 1; }

# Stop Redis before replacing the volume. Writing under a running server would
# leave it serving a dataset that no longer matches what is on disk.
docker stop redis >/dev/null
docker run --rm -v storytime-redis:/d -v /var/tmp:/in alpine sh -c \
  'rm -rf /d/* /d/..?* /d/.[!.]* 2>/dev/null; tar -xzf /in/redis-restore.tar.gz -C /d' >/dev/null
docker start redis >/dev/null
for i in \$(seq 1 30); do
  docker exec redis redis-cli PING 2>/dev/null | grep -q PONG && break
  sleep 1
done
echo \"live keys after restore: \$(docker exec redis redis-cli DBSIZE | tr -d '\r')\"
docker logs --tail 40 redis 2>&1 | grep -iE 'DB loaded|Ready to accept' | sed 's/^/  /'
rm -f /var/tmp/redis-restore.tar.gz
logger -t storytime-redis-restore -p user.notice 'restored $KEY'"

echo "done. The pre-restore safety copy is at /var/tmp/redis-pre-restore.tar.gz on the box"
echo "and is NOT in S3 — copy it off if you may need to roll back."
