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
import json
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

# filter_pm2_json: PM2_SAFE_KEYS may be honoured ONLY inside pm2_env.
# ENV_CONTAINER_RE also matches env / env_production / environment_* — those are
# pure application config, so a key colliding with the allowlist (e.g. "name")
# must still be masked there. Passing preserve=True for every container emitted
# env_production: {"name": "..."} verbatim.
PM2_CASES = [
    # (label, input dict, must_be_absent, must_be_present)
    ("env_production.name is masked",
     {"env_production": {"name": "super-secret-value"}}, "super-secret-value", None),
    ("environment_staging.name is masked",
     {"environment_staging": {"name": "another-secret"}}, "another-secret", None),
    ("plain env.name is masked",
     {"env": {"name": "also-secret"}}, "also-secret", None),
    ("pm2_env secrets still masked",
     {"pm2_env": {"JWT_SECRET": "leakme"}}, "leakme", None),
    # The other direction: 30-pm2/summary.txt is built from these, so pm2_env
    # bookkeeping must survive or the artefact loses the point of capturing it.
    ("pm2_env.name preserved",
     {"pm2_env": {"name": "storytime-api-production"}}, None, "storytime-api-production"),
    ("pm2_env.exec_mode preserved",
     {"pm2_env": {"exec_mode": "cluster_mode"}}, None, "cluster_mode"),
    ("pm2_env.pm_cwd preserved",
     {"pm2_env": {"pm_cwd": "/home/ubuntu/storytime"}}, None, "/home/ubuntu/storytime"),
    # Non-string scalars inside an env container are still candidate secrets:
    # a numeric OTP seed, PIN or account id is as sensitive as a string one.
    # _mask_scalar passes numbers/bools through (right for PM2 bookkeeping,
    # wrong for application config), so env values go through _mask_env_scalar.
    ("numeric env value is masked",
     {"env_production": {"OTP_SECRET": 123456}}, "123456", None),
    ("numeric env value is masked (2)",
     {"env_production": {"LEGACY_PIN": 9876}}, "9876", None),
    ("boolean env value is masked",
     {"env_production": {"DEBUG": True}}, "true", None),
    ("null env value becomes <null>",
     {"env_production": {"NOTHING": None}}, None, "<null>"),
    ("numeric secret inside pm2_env is masked (not allowlisted)",
     {"pm2_env": {"SOME_NUMBER_SECRET": 424242}}, "424242", None),
    # ...while genuine PM2 bookkeeping keeps its real numeric/boolean values,
    # because 30-pm2/summary.txt is built from them.
    ("pm2_env.instances keeps its number",
     {"pm2_env": {"instances": 3}}, None, '"instances": 3'),
    ("pm2_env.pm_id keeps zero",
     {"pm2_env": {"pm_id": 0}}, None, '"pm_id": 0'),
    ("pm2_env.autorestart keeps its boolean",
     {"pm2_env": {"autorestart": True}}, None, '"autorestart": true'),
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
    for label, payload, absent, present in PM2_CASES:
        out = redact.filter_pm2_json(json.dumps(payload))
        if absent is not None and absent in out:
            print(f"FAIL pm2    {label}: {absent!r} survived in {out!r}")
            failed += 1
        elif present is not None and present not in out:
            print(f"FAIL pm2    {label}: lost {present!r} from {out!r}")
            failed += 1
        else:
            print(f"pass pm2    {label}")
    print(f"\n{len(LEAKS)} leak cases, {len(VISIBLE)} visibility cases, "
          f"{len(PM2_CASES)} pm2 cases, {failed} failed")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
