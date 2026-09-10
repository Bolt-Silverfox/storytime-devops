#!/usr/bin/env python3
"""Tests for redact.py — the one hard rule: never emit a configuration value.

Run: python3 capture/lib/redact_test.py

Two directions matter equally and both are asserted here:
  LEAK cases   — a secret value must not survive anywhere on the line. It is not
                 enough that <redacted> appears; the plaintext must be ABSENT.
  VISIBLE cases— nginx directives the capture exists to recover (proxy_pass,
                 client_max_body_size, the SSE timeouts) must NOT be masked.
                 Over-masking has regressed this file before: tightening the
                 value boundary once swallowed proxy_pass, the single most
                 important directive in the vhosts.
"""
import importlib.util
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("redact", os.path.join(_here, "redact.py"))
redact = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(redact)
mask = redact.mask_text

# (line, plaintext that must NOT appear in the output)
LEAKS = [
    # Unterminated quote: the value runs to end of line. Before the fix the
    # bare-token fallback stopped at the first space and emitted the tail.
    ('JWT_SECRET="hunter2 with spaces', "with spaces"),
    ("PGPASSWORD='my secret pass phrase", "phrase"),
    ('API_KEY="abc def ghi', "def ghi"),
    # DATABASE_URL is not secret-ish BY NAME, so URL_CREDS handles it: the
    # credentials are masked, the host/db are deliberately left readable (the
    # capture exists to recover connection targets). Assert the CREDENTIAL is
    # gone, not the whole line.
    ('DATABASE_URL="postgres://u:sup3rpw@host/db more', "sup3rpw"),
    # Balanced quotes (the case that always worked — guard against regression).
    ('JWT_SECRET="hunter2 with spaces"', "hunter2"),
    ("REDIS_PASSWORD='s3cr3t'", "s3cr3t"),
    # Underscore in the name: \b never matched inside JWT_SECRET, so the
    # secret-ish heuristic barely fired. Guard it.
    ("JWT_SECRET=plainvalue", "plainvalue"),
    # nginx idiom where the apparent name is the directive, not the key.
    ('set $upstream_token "abc123";', "abc123"),
    ("env REDIS_PASSWORD=x9y8z7;", "x9y8z7"),
]

# (line, substring that MUST still be visible)
VISIBLE = [
    ("proxy_pass http://127.0.0.1:3500;", "proxy_pass http://127.0.0.1:3500"),
    ("server_name api.storytimeapp.me;", "api.storytimeapp.me"),
    ("client_max_body_size 25m;", "25m"),
    ("proxy_read_timeout 3600s;", "3600s"),
    ("proxy_buffering off;", "off"),
    ("listen 443 ssl;", "443"),
]

def main() -> int:
    failed = 0
    for line, plaintext in LEAKS:
        out = mask(line)
        if plaintext in out:
            print(f"FAIL leak   {line!r}\n            -> {out!r}\n            still contains {plaintext!r}")
            failed += 1
        else:
            print(f"pass leak   {line!r} -> {out!r}")
    for line, must_show in VISIBLE:
        out = mask(line)
        if must_show not in out:
            print(f"FAIL masked {line!r}\n            -> {out!r}\n            lost {must_show!r}")
            failed += 1
        else:
            print(f"pass visible {line!r} -> {out!r}")
    print(f"\n{len(LEAKS)} leak cases, {len(VISIBLE)} visibility cases, {failed} failed")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
