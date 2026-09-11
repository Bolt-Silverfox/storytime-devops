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
#                 dig, no terraform, bad JSON, or any lookup that did not return
#                 a definitive NOERROR/NXDOMAIN answer — a SERVFAIL or REFUSED
#                 reply is a resolver fault, not a zone that disagrees, and an
#                 unanswered lookup proves nothing about the record it was for).
#                 Deliberately NOT 0: "I could not look" must never be
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
    -h|--help)   sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    # A resolver that did not answer is NOT drift. It used to be appended to
    # $drift, which meant one dead resolver made the script exit 1 and announce
    # "the zone does not match" while every record it COULD check matched — a
    # false zone alarm for a network fault. Counting only successful lookups fixed
    # the total-outage case (checked stays 0 -> exit 2); a PARTIAL outage still
    # left checked > 0 and reported drift. Keep the two apart instead.
    #
    # NOT +short: an error REPLY is not the same as no reply, and +short hides the
    # difference. `dig +short` exits 0 and prints nothing for SERVFAIL and for
    # REFUSED exactly as it does for a genuinely empty NOERROR answer, so a broken
    # or refusing resolver read as "this host resolves to NOTHING" — drift, exit 1,
    # a zone alarm for a resolver fault. One invocation of +comments +answer keeps
    # the rcode and the records consistent with each other (asking twice could get
    # two different answers); the answer section is then reduced to the same
    # one-record-per-line shape +short produced.
    if ! raw=$(dig +noall +comments +answer +time=5 +tries=2 A "$host" "@$resolver" 2>/dev/null); then
      unreachable+="  $host via $resolver: dig failed (resolver unreachable?)"$'\n'
      continue
    fi

    # [A-Z0-9] because a reserved rcode dig does not name prints as e.g.
    # RESERVED11 — [A-Z]* would stop at the digit and show "status RESERVED" to
    # the operator. Routing is unaffected (anything but NOERROR/NXDOMAIN is
    # incomplete either way); this only keeps the diagnostic honest. `head -1`
    # rather than tail: BIND 9.18 prints exactly one header per invocation, which
    # was verified under TCP retry after UDP truncation, timeout retry and EDNS
    # fallback — considered, not overlooked.
    status=$(printf '%s\n' "$raw" | sed -n 's/^;;.*status: \([A-Z0-9]*\).*/\1/p' | head -1)

    # NOERROR and NXDOMAIN are the only DEFINITIVE answers: "here is the record"
    # and "that name does not exist". Both are real evidence about the zone, so
    # both feed the drift decision. Every other rcode (SERVFAIL, REFUSED, and a
    # missing header, which means dig returned 0 without a reply we can read) says
    # something about the resolver, not about the zone — incomplete, never drift.
    case "$status" in
      NOERROR|NXDOMAIN) ;;
      "") unreachable+="  $host via $resolver: no DNS response status in reply (lookup incomplete)"$'\n'; continue ;;
      *)  unreachable+="  $host via $resolver: DNS response status $status (lookup incomplete, not drift)"$'\n'; continue ;;
    esac

    # Count only lookups that actually RETURNED a definitive answer. `checked` is
    # the guard that separates "everything matched" from "nothing could be
    # checked": counting attempts meant a total resolver outage left checked > 0,
    # skipped the refuse-to-report-success branch, and exited 1 (DNS drift) on the
    # strength of "dig failed" lines — reporting a zone problem when the real fault
    # was the network. Counting definitive answers makes that case exit 2 as
    # documented, and does the same for a resolver that answers only errors.
    checked=$((checked + 1))

    # Answer section only (comments start with ';'), as "<data>" per record: an A
    # gives an address, a CNAME gives a target ending in a dot. Same two shapes
    # +short printed, so the tests below are unchanged.
    records=$(printf '%s\n' "$raw" | awk '/^;/ { next } $4 == "A" || $4 == "CNAME" { print $5 }')

    got=$(printf '%s\n' "$records" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tr '\n' ' ')
    got="${got% }"
    cname=$(printf '%s\n' "$records" | grep -E '\.$' | head -1)

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
  # Say WHY nothing could be checked. Without this, a zone-wide SERVFAIL and an
  # unplugged network produce the same one-line message.
  [ -n "$unreachable" ] && printf '%s' "$unreachable" >&2
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
