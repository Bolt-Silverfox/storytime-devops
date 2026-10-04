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
docker exec redis redis-cli BGREWRITEAOF >/dev/null
for i in $(seq 1 60); do
  [ "$(docker exec redis redis-cli INFO persistence | tr -d '\r' | sed -n 's/^aof_rewrite_in_progress:\(.*\)$/\1/p')" = "0" ] && break
  sleep 1
done
BEFORE=$(docker exec redis redis-cli DBSIZE | tr -d '\r')
# --rm alpine with the volume mounted read-only: the tar never runs as a process
# that could write to the live dataset.
docker run --rm -v storytime-redis:/d:ro -v /var/tmp:/out alpine \
  tar -czf /out/redis-backup.tar.gz -C /d . >/dev/null
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
OUT=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE" --query StandardOutputContent --output text 2>/dev/null)
ERR=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE" --query StandardErrorContent --output text 2>/dev/null)
echo "status:   $ST"
[ -n "$OUT" ] && echo "$OUT" | sed 's/^/  /'
[ "$ST" = "Success" ] || { [ -n "$ERR" ] && echo "$ERR" | sed 's/^/  stderr: /'; fail "remote backup exited $ST"; }
echo "$KEY"
