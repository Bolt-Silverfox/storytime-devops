#!/usr/bin/env bash
#
# Plan-style unit check for the Woodpecker trust additions in
# infra/github-oidc-deploy.tf: with the new variables empty the deploy roles'
# trust documents are unchanged, and with them set each role gains exactly the
# second, ExternalId-conditioned statement.
#
# It copies the REAL infra/github-oidc-deploy.tf next to stubs (tests/infra/
# harness) and runs `terraform test` (plan only, fake credentials, no AWS
# calls, no state). Needs terraform >= 1.9 and network access to download the
# aws provider once, or PLUGIN_DIR=<a .terraform/providers dir> to run offline.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# a relative PLUGIN_DIR must be resolved before we cd into the temp dir
if [ -n "${PLUGIN_DIR:-}" ]; then PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$HERE"/harness/* "$TMP"/
# The stubs are stored as stubs.tf.txt so the CI validate/tflint discovery
# (git ls-files '*.tf') does not treat this partial harness as a root module.
mv "$TMP/stubs.tf.txt" "$TMP/stubs.tf"
cp "$ROOT/infra/github-oidc-deploy.tf" "$TMP"/
# Test against the aws provider version the real stack is locked to, not the
# newest 5.x: reuse infra/.terraform.lock.hcl (a single source of truth).
cp "$ROOT/infra/.terraform.lock.hcl" "$TMP"/
cd "$TMP"
terraform init -backend=false -input=false -no-color ${PLUGIN_DIR:+-plugin-dir="$PLUGIN_DIR"} >/dev/null
terraform test -no-color
# offline check of scripts/check-woodpecker-external-ids.sh (fake aws, fake ids)
"$HERE/check-external-ids-test.sh"
