#!/usr/bin/env bash
# purge-s3-object-versions.sh — really delete one object from a VERSIONED bucket.
#
# WHY THIS EXISTS
# ---------------
# The backup bucket has versioning enabled (infra/backups.tf), which is
# deliberate: it is what makes an overwritten or maliciously deleted dump
# recoverable. The consequence is that `aws s3 rm` DOES NOT DELETE ANYTHING. It
# writes a delete marker, the object stops appearing in `aws s3 ls`, and every
# previous version stays fully readable — in this bucket until the lifecycle
# rule's noncurrent_version_expiration (7 days) gets to it.
#
# docs/migration.md step 5 stages a PLAINTEXT pg_dump of the production database
# — children's personal data under GDPR — into that bucket so the new box can
# read it. "Cleaning up" with `aws s3 rm` would leave that dump recoverable for a
# week while telling the operator it was gone. That is the bug this script fixes.
#
# It deletes every version AND every delete marker of exactly one key, then
# VERIFIES the key is gone, and fails loudly if anything survived. Deleting a
# specific version-id does not create a new delete marker, so the purge
# converges; a prior `aws s3 rm` leaves a marker behind, which is why markers are
# enumerated too.
#
# Run it with OPERATOR credentials. The instance role deliberately has no
# s3:DeleteObject, and no s3:DeleteObjectVersion either.
#
#   ./purge-s3-object-versions.sh <bucket> <key>
#
# Exit codes: 0 = the key has no versions and no delete markers left.
#             1 = usage/precondition error, or something survived.

set -euo pipefail

BUCKET="${1:-}"
KEY="${2:-}"

if [ -z "$BUCKET" ] || [ -z "$KEY" ]; then
  echo "usage: $(basename "$0") <bucket> <key>" >&2
  echo "  e.g. $(basename "$0") storytime-all-v2-backups postgres/restore-in/source.dump" >&2
  exit 1
fi

# The key is interpolated into a JMESPath string literal below. A single quote
# would break out of it, and a wildcard would widen the blast radius of a
# deletion loop — refuse rather than guess.
case "$KEY" in
*\'* | *\** | *\?*)
  echo "FATAL: key must not contain a quote or a wildcard: $KEY" >&2
  exit 1
  ;;
esac

# --prefix narrows the listing server-side; the Key=='...' filter is what makes it
# exact, so a sibling object whose name merely starts with $KEY is never touched.
list_ids() { # $1 = Versions | DeleteMarkers
  aws s3api list-object-versions \
    --bucket "$BUCKET" --prefix "$KEY" \
    --query "$1[?Key=='$KEY'].VersionId" \
    --output text | tr '\t' '\n' | grep -v -e '^None$' -e '^$' || true
}

deleted=0
purged_all=false

# list-object-versions pages at 1000 entries, so loop until a listing comes back
# empty rather than assuming one pass is enough. The bound stops a silent
# permissions failure from spinning forever.
#
# A failing delete is NOT allowed to abort the script through `set -e`: the whole
# value of this script is the verification report at the end, and dying on the
# first AccessDenied would skip it and leave the operator guessing whether the
# dump is gone. Failures are counted and surfaced there instead.
for _attempt in $(seq 1 20); do
  ids=$( (list_ids Versions; list_ids DeleteMarkers) | sort -u)
  if [ -z "$ids" ]; then
    purged_all=true
    break
  fi

  progress=0
  while IFS= read -r vid; do
    [ -n "$vid" ] || continue
    echo "deleting version $vid"
    if aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$vid" >/dev/null; then
      deleted=$((deleted + 1))
      progress=$((progress + 1))
    else
      echo "WARN: could not delete version $vid" >&2
    fi
  done <<<"$ids"

  # Nothing could be deleted this pass, so another pass would list the same ids
  # and fail the same way. Stop and let the verification below report it.
  [ "$progress" -eq 0 ] && break
done

# VERIFY, INDEPENDENTLY. Not optional: the whole point is that the previous
# procedure trusted a command which had deleted nothing.
remaining_versions=$(list_ids Versions | wc -l | tr -d ' ')
remaining_markers=$(list_ids DeleteMarkers | wc -l | tr -d ' ')

if [ "$purged_all" != "true" ] || [ "$remaining_versions" != "0" ] || [ "$remaining_markers" != "0" ]; then
  echo "FATAL: purge INCOMPLETE for s3://$BUCKET/$KEY" >&2
  echo "  versions left:       $remaining_versions" >&2
  echo "  delete markers left: $remaining_markers" >&2
  echo "THE OBJECT IS STILL RECOVERABLE. Check s3:DeleteObjectVersion permission," >&2
  echo "object lock / legal hold, and MFA-delete on the bucket, then re-run." >&2
  exit 1
fi

echo "purge ok: s3://$BUCKET/$KEY — $deleted version(s)/marker(s) deleted, none remaining"
