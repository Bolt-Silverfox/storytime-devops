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
#
# The filtering is `sed`, NOT `grep -v ... || true`. grep exits 1 when it filters
# every line away, which is the ordinary "no versions left" case — hence the
# `|| true`. But that `|| true` also swallowed a FAILURE of the aws call itself
# (AccessDenied, no credentials, throttling): the listing came back empty, the
# loop concluded there was nothing to delete, the verification below listed
# nothing either, and the script printed "purge ok" while a plaintext dump of
# children's personal data was still fully recoverable. That is the exact failure
# this script exists to prevent, so an empty result and a failed lookup must be
# distinguishable. sed exits 0 on empty input, so no suppression is needed and
# pipefail can propagate a real failure.
list_ids() { # $1 = Versions | DeleteMarkers
  aws s3api list-object-versions \
    --bucket "$BUCKET" --prefix "$KEY" \
    --query "$1[?Key=='$KEY'].VersionId" \
    --output text | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d'
}

# list_ids into a variable, distinguishing "empty" from "could not look".
# Returns 0 with the ids on stdout, or 1 if the listing failed.
list_ids_checked() {
  local out
  if ! out=$(list_ids "$1"); then
    return 1
  fi
  # Only emit a trailing newline when there is something to emit, so `wc -l`
  # counts a single id as 1 and an empty result as 0. `printf '%s'` alone would
  # report one id as 0 lines and make the verification below claim the object was
  # gone — the same false "purge ok" this change exists to remove.
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Count, propagating a listing failure instead of reporting zero.
count_ids() {
  local out
  out=$(list_ids_checked "$1") || return 1
  printf '%s' "$out" | grep -c . || true
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
listing_failed=false
for _attempt in $(seq 1 20); do
  if ! vers=$(list_ids_checked Versions) || ! marks=$(list_ids_checked DeleteMarkers); then
    echo "WARN: could not list object versions (permissions? credentials? throttling?)" >&2
    listing_failed=true
    break
  fi
  ids=$(printf '%s\n%s\n' "$vers" "$marks" | sed -e '/^$/d' | sort -u)
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
# A failure to VERIFY is itself a failure: report it, never treat it as zero.
verify_failed=false
if ! remaining_versions=$(count_ids Versions); then
  verify_failed=true; remaining_versions="unknown"
fi
if ! remaining_markers=$(count_ids DeleteMarkers); then
  verify_failed=true; remaining_markers="unknown"
fi

if [ "$listing_failed" = "true" ] || [ "$verify_failed" = "true" ] \
   || [ "$purged_all" != "true" ] || [ "$remaining_versions" != "0" ] || [ "$remaining_markers" != "0" ]; then
  echo "FATAL: purge INCOMPLETE for s3://$BUCKET/$KEY" >&2
  echo "  versions left:       $remaining_versions" >&2
  echo "  delete markers left: $remaining_markers" >&2
  echo "THE OBJECT IS STILL RECOVERABLE. Check s3:DeleteObjectVersion permission," >&2
  echo "object lock / legal hold, and MFA-delete on the bucket, then re-run." >&2
  exit 1
fi

echo "purge ok: s3://$BUCKET/$KEY — $deleted version(s)/marker(s) deleted, none remaining"
