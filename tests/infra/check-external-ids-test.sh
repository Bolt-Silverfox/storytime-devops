#!/usr/bin/env bash
# Offline test of scripts/check-woodpecker-external-ids.sh with a fake `aws` on
# PATH and FAKE ExternalIds. Asserts the verdicts and that no value, and no
# hash of a value, ever reaches the output.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../scripts/check-woodpecker-external-ids.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"

# fake aws: serves $TMP/live/<role-name>.json; missing file => failure.
cat > "$TMP/bin/aws" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "iam get-role" ] || { echo "unexpected aws call: $*" >&2; exit 99; }
role="$4"
[ -f "$LIVE_DIR/$role.json" ] || { echo "NoSuchEntity secret-looking-text" >&2; exit 254; }
cat "$LIVE_DIR/$role.json"
FAKE
chmod +x "$TMP/bin/aws"
export LIVE_DIR="$TMP/live"; mkdir "$LIVE_DIR"

mkdoc() { # role id [shape]
  python3 -I - "$1" "$2" "${3:-str}" <<'PY' > "$LIVE_DIR/$1.json"
import json, sys
role, eid, shape = sys.argv[1:4]
oidc = {"Effect": "Allow", "Action": "sts:AssumeRoleWithWebIdentity", "Principal": {"Federated": "x"}}
stmts = [oidc]
if eid != "-":
    v = eid if shape == "str" else [eid, "extra-second-value-extra-second-value"]
    stmts.append({"Sid": "WoodpeckerStorytimeLane", "Effect": "Allow", "Action": "sts:AssumeRole",
                  "Principal": {"AWS": "arn:aws:iam::772641335580:role/shared-spot-agent-storytime"},
                  "Condition": {"StringEquals": {"sts:ExternalId": v}}})
print(json.dumps({"Version": "2012-10-17", "Statement": stmts}))
PY
}
FAKE_API=fakeapi0123456789fakeapi0123456789fakeapi
FAKE_ADMIN=fakeadmin123456789fakeadmin123456789fakeadm
FAKE_WEB=fakeweb01234567890fakeweb01234567890fakeweb
FAKE_WAPI=fakewapi12345678901fakewapi12345678901fakew
FAKE_WWEB=fakewweb12345678901fakewweb12345678901fakew
cat > "$TMP/tfvars.json" <<JSON
{"woodpecker_agent_role_arns": [], "woodpecker_external_ids": {
 "api": "$FAKE_API", "admin": "$FAKE_ADMIN", "web": "$FAKE_WEB",
 "waitlist-api": "$FAKE_WAPI", "waitlist-web": "$FAKE_WWEB"}}
JSON

mkdoc storytime-gha-deploy-api "$FAKE_API"
mkdoc storytime-gha-deploy-admin "${FAKE_ADMIN}-rotated"      # DIFFERENT
mkdoc storytime-gha-deploy-web -                               # no Woodpecker statement: MISSING-LIVE
# waitlist-api: no such role (aws fails)                       # MISSING-LIVE
mkdoc storytime-gha-deploy-waitlist-web "$FAKE_WWEB" list      # two values: DIFFERENT (not exactly one)

set +e
out="$(PATH="$TMP/bin:$PATH" "$SCRIPT" "$TMP/tfvars.json" 2>&1)"; rc=$?
set -e
want="api            SAME
admin          DIFFERENT
web            MISSING-LIVE
waitlist-api   MISSING-LIVE
waitlist-web   DIFFERENT"
fail=0
[ "$out" = "$want" ] || { echo "FAIL verdicts:"; echo "$out"; fail=1; }
[ "$rc" -ne 0 ] || { echo "FAIL: exit code must be non-zero unless all SAME"; fail=1; }
for v in "$FAKE_API" "$FAKE_ADMIN" "$FAKE_WEB" "$FAKE_WAPI" "$FAKE_WWEB" secret-looking-text rotated; do
  case "$out" in *"$v"*) echo "FAIL: output leaks '$v'"; fail=1;; esac
done
for v in "$FAKE_API" "$FAKE_ADMIN" "$FAKE_WWEB"; do
  hx="$(printf %s "$v" | shasum -a 256 | cut -c1-12)"
  case "$out" in *"$hx"*) echo "FAIL: output leaks a hash"; fail=1;; esac
done

# all SAME => exit 0
mkdoc storytime-gha-deploy-admin "$FAKE_ADMIN"
mkdoc storytime-gha-deploy-web "$FAKE_WEB"
mkdoc storytime-gha-deploy-waitlist-api "$FAKE_WAPI"
mkdoc storytime-gha-deploy-waitlist-web "$FAKE_WWEB"
if ! out2="$(PATH="$TMP/bin:$PATH" "$SCRIPT" "$TMP/tfvars.json" 2>&1)"; then echo "FAIL: all-SAME must exit 0"; echo "$out2"; fail=1; fi
[ "$(printf '%s\n' "$out2" | grep -c ' SAME$')" = 5 ] || { echo "FAIL: expected five SAME"; fail=1; }

# unreadable tfvars
if PATH="$TMP/bin:$PATH" "$SCRIPT" "$TMP/nope.json" >/dev/null 2>&1; then echo "FAIL: missing tfvars must fail"; fail=1; fi
[ "$fail" = 0 ] && echo "check-external-ids: ok" || exit 1
