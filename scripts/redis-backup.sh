#!/usr/bin/env bash
# Back up the Redis container's data volume to S3, over SSM.
#
# WHY NOT IN THE BOOTSTRAP: user-data is at 15038 of 16384 gzipped bytes, and
# `user_data_base64` has NO length validation in the provider — overflow fails at
# RunInstances, after Terraform has decided to replace the instance. Two scripts
# would not fit. These run from an operator machine instead.
#
# WHY THE WHOLE /data AND NOT JUST dump.rdb: the container runs
# `redis-server --appendonly yes`, so on start Redis loads `appendonlydir` and
# IGNORES dump.rdb. Restoring only the RDB gives a silently EMPTY Redis. The tar
# carries both.
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
BUCKET="${BUCKET:-storytime-prod-backups}"
STACK="${STACK:-storytime-prod}"
PREFIX="redis"

fail() { echo "REDIS BACKUP FAILED: $*" >&2; exit 1; }

# Resolve the instance BY TAG, not by id: the box is replaceable and a pinned id
# is the thing that breaks after a replacement.
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Stack,Values=$STACK" "Name=tag:Name,Values=$STACK-app" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text) || fail "could not query instances"
[ -n "$INSTANCE" ] || fail "no running instance tagged Stack=$STACK Name=$STACK-app"
[ "$(wc -w <<<"$INSTANCE")" -eq 1 ] || fail "more than one instance matched: $INSTANCE"

STAMP=$(date -u +%Y/%m/%d/%Y%m%dT%H%M%SZ)
KEY="$PREFIX/$STACK/$STAMP.tar.gz"
echo "instance: $INSTANCE"
echo "target:   s3://$BUCKET/$KEY"

# BGREWRITEAOF first so the AOF is compacted to a fresh base before the tar. A
# live incr file can otherwise be captured mid-write; Redis tolerates a truncated
# AOF tail (aof-load-truncated defaults to yes), but starting from a clean base
# makes that a non-question rather than a tolerated risk.
read -r -d '' SCRIPT <<'REMOTE' || true
set -euo pipefail
# `-e` IS REQUIRED. Without it redis-cli exits 0 even when Redis replies with an
# error, and Redis rejects BGREWRITEAOF when it cannot fork the rewrite child. The
# old code then saw aof_rewrite_in_progress:0 on the FIRST poll, read that as
# "finished", and archived the un-compacted AOF — a backup quietly weaker than its
# own stated guarantee.
docker exec redis redis-cli -e BGREWRITEAOF >/dev/null \
  || { echo "BGREWRITEAOF was rejected by Redis — refusing to archive without a fresh AOF base" >&2; exit 1; }

# Wait on BOTH flags. An RDB save in flight makes Redis SCHEDULE the rewrite and
# still reply OK, so in_progress stays 0 while scheduled is 1 — polling only
# in_progress would exit immediately and archive the old AOF.
for i in $(seq 1 120); do
  P=$(docker exec redis redis-cli INFO persistence | tr -d '\r')
  IN=$(sed -n 's/^aof_rewrite_in_progress:\(.*\)$/\1/p' <<<"$P")
  SCHED=$(sed -n 's/^aof_rewrite_scheduled:\(.*\)$/\1/p' <<<"$P")
  [ "$IN" = "0" ] && [ "${SCHED:-0}" = "0" ] && break
  sleep 1
done
# And confirm it actually succeeded. A failed rewrite leaves the previous AOF
# intact, so the archive would still load — but it would not be the fresh base
# this script promises, and silently degrading that is worse than stopping.
STATUS=$(docker exec redis redis-cli INFO persistence | tr -d '\r' | sed -n 's/^aof_last_bgrewrite_status:\(.*\)$/\1/p')
[ "$STATUS" = "ok" ] \
  || { echo "aof_last_bgrewrite_status=$STATUS after the rewrite — refusing to archive" >&2; exit 1; }
BEFORE=$(docker exec redis redis-cli DBSIZE | tr -d '\r')

# REDIS IS STOPPED FOR THE ARCHIVE. The rewrite-status checks above are not a
# lock: Redis 7.4 enables automatic AOF rewrites by default, so a rewrite can
# begin AFTER those checks and while tar is reading. The manifest swap is atomic,
# but the multi-part file SET is not snapshotted atomically — so tar can capture a
# manifest naming files from one generation alongside files from another, or miss
# a file deleted during the switch. That does not degrade the archive; it can make
# it unloadable, which is the one outcome a backup may not have.
#
# A read-only mount does not help. It stops the tar writing; it does not stop
# Redis rewriting underneath it.
#
# THE COST IS A FEW SECONDS OF DOWNTIME per backup, which is why this script is
# for bracketing a deliberate operation (an instance replacement) rather than for
# a cron. If a non-disruptive periodic backup is ever wanted, the mechanism is
# different: `redis-cli --rdb` asks the server for a point-in-time RDB over the
# wire, and the restore side then has to rebuild the AOF from it. Do not simply
# delete the stop below.
REDIS_STOPPED=0
# Readiness is CHECKED here too, not just on the happy path. `docker start`
# returning 0 means the container was started, not that Redis answers requests —
# so the first version of this trap could print "redis restarted" while Redis was
# still unavailable, which is the most misleading thing a recovery path can do.
redis_ready() {
  local i
  for i in $(seq 1 30); do
    docker exec redis redis-cli PING 2>/dev/null | grep -q PONG && return 0
    sleep 1
  done
  return 1
}
restart_redis() {
  if [ "$REDIS_STOPPED" = '1' ]; then
    if docker start redis >/dev/null 2>&1 && redis_ready; then
      echo 'redis restarted and answering PING' >&2
    else
      echo 'REDIS IS NOT SERVING after the backup — it is stopped or unresponsive. Recover by hand: docker start redis; docker exec redis redis-cli PING' >&2
      logger -t storytime-redis-backup -p user.crit 'redis not serving after backup; manual recovery needed' 2>/dev/null || true
    fi
  fi
}
# EXIT, not ERR: this must also run if the script is interrupted part-way, because
# leaving production Redis stopped is worse than a missing backup.
trap restart_redis EXIT
docker stop redis >/dev/null || { echo 'could not stop redis — refusing to archive a live volume' >&2; exit 1; }
REDIS_STOPPED=1

docker run --rm -v storytime-redis:/d:ro -v /var/tmp:/out alpine \
  tar -czf /out/redis-backup.tar.gz -C /d . >/dev/null

docker start redis >/dev/null || { echo 'archive taken but redis did not restart' >&2; exit 1; }
REDIS_STOPPED=0
redis_ready || { echo 'redis restarted but never answered PING' >&2; exit 1; }
trap - EXIT

SIZE=$(stat -c %s /var/tmp/redis-backup.tar.gz)
aws s3 cp --region eu-west-1 --only-show-errors /var/tmp/redis-backup.tar.gz "s3://BUCKET_PLACEHOLDER/KEY_PLACEHOLDER"
rm -f /var/tmp/redis-backup.tar.gz
echo "keys=$BEFORE bytes=$SIZE"
logger -t storytime-redis-backup -p user.notice "backup ok: KEY_PLACEHOLDER ($SIZE bytes, $BEFORE keys)"
REMOTE
SCRIPT=${SCRIPT//BUCKET_PLACEHOLDER/$BUCKET}
SCRIPT=${SCRIPT//KEY_PLACEHOLDER/$KEY}

# --cli-input-json from a FILE, not --parameters as a shell string. Passing the
# JSON inline mangles the \n escapes inside the script: the first attempt reached
# the instance as `set: pipefailndocker`, i.e. every newline collapsed to a
# literal n. One command string per array element would also work; a file is
# simpler to debug because it is the exact bytes the API receives.
export SCRIPT
REQ=$(mktemp /var/tmp/ssm-req.XXXXXX.json)
trap 'rm -f "$REQ"' EXIT
python3 - "$INSTANCE" "$REQ" <<'PYEOF'
import json, os, sys
instance, path = sys.argv[1], sys.argv[2]
json.dump({
    "InstanceIds": [instance],
    "DocumentName": "AWS-RunShellScript",
    "Comment": "redis backup to s3",
    "Parameters": {"commands": [os.environ["SCRIPT"]]},
}, open(path, "w"))
PYEOF
CID=$(aws ssm send-command --cli-input-json "file://$REQ" \
  --query 'Command.CommandId' --output text) || fail "send-command failed"

for _ in $(seq 1 60); do
  sleep 5
  ST=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  case "$ST" in Success|Failed|Cancelled|TimedOut) break;; esac
done
# A non-terminal status here means WE gave up watching, not that the job failed.
# Saying "exited Pending" would read as a failure and invite a second run on top
# of a backup that is still uploading.
case "$ST" in
  Success|Failed|Cancelled|TimedOut) ;;
  *)
    echo "stopped waiting after ~5 minutes; the remote command is still $ST and may yet finish." >&2
    echo "check it with: aws ssm get-command-invocation --command-id $CID --instance-id $INSTANCE" >&2
    fail "timed out watching the remote backup (it was NOT cancelled)"
    ;;
esac
OUT=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE" --query StandardOutputContent --output text 2>/dev/null)
ERR=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE" --query StandardErrorContent --output text 2>/dev/null)
echo "status:   $ST"
[ -n "$OUT" ] && echo "$OUT" | sed 's/^/  /'
[ "$ST" = "Success" ] || { [ -n "$ERR" ] && echo "$ERR" | sed 's/^/  stderr: /'; fail "remote backup exited $ST"; }
echo "$KEY"
