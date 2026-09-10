#!/usr/bin/env bash
# check-dns.sh — is the Namecheap zone still pointing where Terraform says?
#
# WHY THIS EXISTS
# ---------------
# DNS for this platform is edited BY HAND at Namecheap (see infra/dns.tf for why
# that is a decision and not an oversight). Terraform therefore knows what the
# records SHOULD be — `terraform output dns_records_required` — but nothing ever
# compared that to what the zone ACTUALLY serves. The runbook's `dig` checks are
# one-shot, at cutover, by a human who is looking for them.
#
# So the gap this closes is the quiet one: a record edited months later, a typo
# in one host out of six, an A record deleted during unrelated zone maintenance,
# or an EIP reallocated while the zone still names the old address. None of that
# surfaces until users cannot reach the platform.
#
# It needs NO credentials and NO Namecheap API: it compares Terraform's intent
# against public resolution, from more than one resolver, because a single
# resolver's cache is not evidence.
#
#   ./check-dns.sh                        # read intent from infra/ via terraform
#   ./check-dns.sh --from-json f.json     # read intent from a saved output (CI/tests)
#   ./check-dns.sh --resolver 1.1.1.1 --resolver 8.8.8.8
#
# Exit codes: 0 = every expected record matches everywhere it was checked.
#             1 = drift (a mismatch, a missing record, or a CNAME where an A is
#                 expected).
#             2 = could not perform the check, or could not perform ALL of it (no
#                 dig, no terraform, bad JSON, or any lookup that did not
#                 return). Deliberately NOT 0: "I could not look" must never be
#                 reported as "nothing is wrong" — and deliberately not 1
#                 either, because an unreachable resolver is a network fault, not
#                 a zone that disagrees with Terraform.
#
# Run it from anywhere; paths are resolved relative to the repo.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="$(dirname -- "$SCRIPT_DIR")/infra"

FROM_JSON=""
RESOLVERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --from-json) FROM_JSON="${2:?--from-json needs a path}"; shift 2 ;;
    --resolver)  RESOLVERS+=("${2:?--resolver needs an address}"); shift 2 ;;
    -h|--help)   sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Two independent public resolvers by default. One resolver agreeing with
# Terraform proves only that one cache agrees.
if [ "${#RESOLVERS[@]}" -eq 0 ]; then
  RESOLVERS=(1.1.1.1 8.8.8.8)
fi

if ! command -v dig >/dev/null 2>&1; then
  echo "::error::check-dns.sh needs dig (bind9-dnsutils / bind-utils). Refusing to report success without having resolved anything." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Terraform's intent.
# ---------------------------------------------------------------------------
if [ -n "$FROM_JSON" ]; then
  [ -f "$FROM_JSON" ] || { echo "::error::no such file: $FROM_JSON" >&2; exit 2; }
  intent=$(cat -- "$FROM_JSON")
else
  command -v terraform >/dev/null 2>&1 || { echo "::error::terraform not on PATH (or pass --from-json)." >&2; exit 2; }
  [ -d "$INFRA_DIR" ] || { echo "::error::no infra directory at $INFRA_DIR" >&2; exit 2; }
  if ! intent=$(terraform -chdir="$INFRA_DIR" output -json dns_records_required 2>/dev/null); then
    echo "::error::could not read 'terraform output -json dns_records_required' from $INFRA_DIR." >&2
    echo "::error::Select the right workspace first (terraform -chdir=$INFRA_DIR workspace select <env>)." >&2
    exit 2
  fi
fi

command -v jq >/dev/null 2>&1 || { echo "::error::check-dns.sh needs jq." >&2; exit 2; }

if ! echo "$intent" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::dns_records_required is not a JSON array — cannot compare. Got: $(echo "$intent" | head -c 200)" >&2
  exit 2
fi

count=$(echo "$intent" | jq 'length')
if [ "$count" -eq 0 ]; then
  # dns.tf empties this output when associate_eip = false: a stack that does not
  # hold the Elastic IP has no opinion about where DNS should point.
  echo "check-dns: no expected records (associate_eip = false, or no hostnames). Nothing to compare."
  exit 0
fi

# ---------------------------------------------------------------------------
# Compare.
# ---------------------------------------------------------------------------
drift=""
unreachable=""
checked=0

# `read -r` over a TSV of host<TAB>value. Hostnames and IPv4 addresses contain no
# tabs or newlines, so this is unambiguous.
while IFS=$'\t' read -r host want; do
  [ -n "${host:-}" ] || continue
  for resolver in "${RESOLVERS[@]}"; do
    # +short prints a CNAME target on its own line before the A records, so
    # filter to things that look like IPv4 rather than assuming line 1.
    # A resolver that did not answer is NOT drift. It used to be appended to
    # $drift, which meant one dead resolver made the script exit 1 and announce
    # "the zone does not match" while every record it COULD check matched — a
    # false zone alarm for a network fault. Counting only successful lookups fixed
    # the total-outage case (checked stays 0 -> exit 2); a PARTIAL outage still
    # left checked > 0 and reported drift. Keep the two apart instead.
    if ! raw=$(dig +short +time=5 +tries=2 A "$host" "@$resolver" 2>/dev/null); then
      unreachable+="  $host via $resolver: dig failed (resolver unreachable?)"$'\n'
      continue
    fi

    # Count only lookups that actually RETURNED. `checked` is the guard that
    # separates "everything matched" from "nothing could be checked": counting
    # attempts meant a total resolver outage left checked > 0, skipped the
    # refuse-to-report-success branch, and exited 1 (DNS drift) on the strength
    # of "dig failed" lines — reporting a zone problem when the real fault was
    # the network. Counting successes makes that case exit 2 as documented.
    checked=$((checked + 1))

    got=$(printf '%s\n' "$raw" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tr '\n' ' ')
    got="${got% }"
    cname=$(printf '%s\n' "$raw" | grep -E '\.$' | head -1)

    # A CNAME is drift even when it happens to resolve to the right address.
    # dig returns the CNAME AND the address it resolves to, so testing $got first
    # would silently accept a zone where the expected A record has been replaced
    # by a CNAME — which is a different record than Terraform declares, breaks the
    # EIP-remap cutover model (the address stops being the lever), and cannot even
    # be expressed at a zone apex.
    if [ -n "$cname" ]; then
      drift+="  $host via $resolver: expected A $want, found CNAME -> $cname${got:+ (currently resolving to $got)}"$'\n'
      continue
    fi

    if [ -z "$got" ]; then
      drift+="  $host via $resolver: expected A $want, resolved to NOTHING (record missing or NXDOMAIN)"$'\n'
      continue
    fi

    if [ "$got" != "$want" ]; then
      drift+="  $host via $resolver: expected A $want, got $got"$'\n'
    fi
  done
done < <(echo "$intent" | jq -r '.[] | select(.type == "A") | [.host, .value] | @tsv')

if [ "$checked" -eq 0 ]; then
  echo "::error::there were $count expected record(s) but none were checked — refusing to report success." >&2
  exit 2
fi

# Real drift wins over an incomplete check: a mismatch is still a mismatch even
# if another resolver was unreachable, and exit 1 is the actionable answer.
if [ -n "$drift" ]; then
  echo "::error::DNS drift — the zone does not match 'terraform output dns_records_required':" >&2
  printf '%s' "$drift" >&2
  if [ -n "$unreachable" ]; then
    echo "Additionally, some lookups did not complete (the drift above is from the ones that did):" >&2
    printf '%s' "$unreachable" >&2
  fi
  echo "Fix at Namecheap -> Domain List -> Manage -> Advanced DNS -> Host Records," >&2
  echo "or re-check which stack currently holds the Elastic IP (terraform output service_address)." >&2
  exit 1
fi

# Everything that answered matched, but not everything answered. That is "could
# not perform the check", i.e. 2 — not 0, because a record that was never
# resolved has not been shown to be right.
if [ -n "$unreachable" ]; then
  echo "::error::$checked lookup(s) matched, but some did not complete, so this is not a clean pass:" >&2
  printf '%s' "$unreachable" >&2
  echo "::error::Re-run once the resolver is reachable. Exiting 2 (could not fully check), not 0." >&2
  exit 2
fi

echo "check-dns: OK — $count record(s) match across ${#RESOLVERS[@]} resolver(s) ($checked lookup(s))."
