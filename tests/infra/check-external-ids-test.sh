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

# isolated failure modes: everything else SAME, one thing wrong
run_script() { set +e; out3="$(PATH="$TMP/bin:$PATH" "$SCRIPT" "$1" 2>&1)"; rc3=$?; set -e; }

# (a) aws fails for one role, the other four SAME: must NOT exit 0
mv "$LIVE_DIR/storytime-gha-deploy-web.json" "$TMP/web.json.bak"
run_script "$TMP/tfvars.json"
[ "$rc3" -ne 0 ] || { echo "FAIL: an aws failure with the rest SAME exited 0"; fail=1; }
[ "$(printf '%s\n' "$out3" | grep -c ' SAME$')" = 4 ] || { echo "FAIL: expected four SAME"; fail=1; }
case "$out3" in *"web            MISSING-LIVE"*) ;; *) echo "FAIL: aws failure must print MISSING-LIVE"; fail=1;; esac
mv "$TMP/web.json.bak" "$LIVE_DIR/storytime-gha-deploy-web.json"

# (b) tfvars lacks one key: that role prints MISSING-TFVARS, exit non-zero
python3 -I - "$TMP/tfvars.json" "$TMP/tfvars-nokey.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["woodpecker_external_ids"]["web"]
json.dump(d, open(sys.argv[2], "w"))
PY
run_script "$TMP/tfvars-nokey.json"
case "$out3" in *"web            MISSING-TFVARS"*) ;; *) echo "FAIL: missing tfvars key must print MISSING-TFVARS"; echo "$out3"; fail=1;; esac
[ "$rc3" -ne 0 ] || { echo "FAIL: a missing tfvars key exited 0"; fail=1; }

# (c) malformed live JSON: ERROR path, no content echoed, exit non-zero
printf '{"Statement": [ not json secret-garbage' > "$LIVE_DIR/storytime-gha-deploy-web.json"
run_script "$TMP/tfvars.json"
case "$out3" in *"web            ERROR"*) ;; *) echo "FAIL: malformed live JSON must print ERROR"; echo "$out3"; fail=1;; esac
case "$out3" in *secret-garbage*|*Traceback*) echo "FAIL: ERROR path leaked content"; fail=1;; esac
[ "$rc3" -ne 0 ] || { echo "FAIL: malformed live JSON exited 0"; fail=1; }
mkdoc storytime-gha-deploy-web "$FAKE_WEB"

# unreadable tfvars
if PATH="$TMP/bin:$PATH" "$SCRIPT" "$TMP/nope.json" >/dev/null 2>&1; then echo "FAIL: missing tfvars must fail"; fail=1; fi
[ "$fail" = 0 ] && echo "check-external-ids: ok" || exit 1
