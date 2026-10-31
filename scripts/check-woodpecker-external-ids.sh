#!/usr/bin/env bash
#
# Compares, per deploy role, the ExternalId currently in the LIVE trust policy
# with the one in your woodpecker tfvars file, and prints ONLY a verdict per
# role: SAME, DIFFERENT, MISSING-LIVE or MISSING-TFVARS. It never prints either
# value or either hash. Read-only: the only AWS call is `aws iam get-role`.
#
# Use it before the first `tofu plan` on a stack whose Woodpecker trust was
# applied by hand (docs/woodpecker.md, "Reconcile with the already-applied
# state"). Every line must say SAME before you apply anything.
#
# usage: scripts/check-woodpecker-external-ids.sh [tfvars.json]
#   tfvars.json  default: $HOME/.config/storytime/woodpecker.tfvars.json
#   env: AWS_PROFILE / AWS_REGION as usual (account 772316781095);
#        NAME_PREFIX (default storytime) for the role names
# exit: 0 only if every role is SAME.
set -euo pipefail

TFVARS="${1:-$HOME/.config/storytime/woodpecker.tfvars.json}"
PREFIX="${NAME_PREFIX:-storytime}"
[ -r "$TFVARS" ] || { echo "cannot read tfvars file: $TFVARS" >&2; exit 2; }

rc=0
for svc in api admin web waitlist-api waitlist-web; do
  role="${PREFIX}-gha-deploy-${svc}"
  # stderr of aws is discarded: a failure message must never be able to carry
  # policy text. A failed call is reported as MISSING-LIVE.
  if ! doc="$(aws iam get-role --role-name "$role" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)"; then
    printf '%-14s %s\n' "$svc" "MISSING-LIVE"; rc=1; continue
  fi
  # The two inputs reach python through the environment, not argv (no process
  # listing exposure). -I: ignore the cwd and user site. Any exception prints a
  # fixed word, never a traceback (which could quote a value).
  verdict="$(LIVE_DOC="$doc" TFVARS="$TFVARS" SVC="$svc" python3 -I -c '
import hashlib, json, os, sys
def h(v): return hashlib.sha256(v.encode()).hexdigest()
try:
    live = json.loads(os.environ["LIVE_DOC"])
    want = json.load(open(os.environ["TFVARS"]))["woodpecker_external_ids"].get(os.environ["SVC"])
    stmts = live["Statement"]
    stmts = stmts if isinstance(stmts, list) else [stmts]
    ids = []
    for s in stmts:
        if s.get("Sid") == "WoodpeckerStorytimeLane":
            v = (s.get("Condition", {}).get("StringEquals", {}) or {}).get("sts:ExternalId")
            ids += v if isinstance(v, list) else ([v] if v else [])
    if want is None:
        print("MISSING-TFVARS")
    elif not ids:
        print("MISSING-LIVE")
    elif len(ids) == 1 and h(ids[0]) == h(want):
        print("SAME")
    else:
        print("DIFFERENT")
except Exception:
    print("ERROR")
')" || verdict="ERROR"
  printf '%-14s %s\n' "$svc" "$verdict"
  [ "$verdict" = SAME ] || rc=1
done
exit "$rc"
