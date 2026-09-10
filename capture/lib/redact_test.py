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
    # Secret-ish argument in the MIDDLE of a whitespace-separated statement with
    # an UNQUOTED value. The quoted twin (`set $upstream_token "abc123";`) was
    # already caught above; without a quote every one of these was emitted
    # verbatim, because ASSIGNMENT judges the line on the leading directive and
    # then resumes past the real value.
    ("proxy_set_header X-Api-Key abc123SECRET;", "abc123SECRET"),
    ("fastcgi_param HTTP_AUTHORIZATION topsecretvalue;", "topsecretvalue"),
    ("add_header X-Webhook-Token wh_topsecret;", "wh_topsecret"),
    ("set $api_key abc123SECRET;", "abc123SECRET"),
    # Two tokens after the name: masking only the first would leave the rest.
    ("proxy_set_header Authorization Bearer abc123SECRET;", "abc123SECRET"),
    # Crontabs go through this filter too, and an inline flag is the usual shape.
    ("0 3 * * * /usr/bin/backup.sh --password sekrit2", "sekrit2"),
    # INDENTED, which is how nginx -T actually prints them. The first attempt at
    # the fix above passed every unindented case and leaked every indented one:
    # leading whitespace let a regex match start at the directive and consume the
    # value. Assert the real shape, not the convenient one.
    ("    proxy_set_header X-Api-Key live_abc123;", "live_abc123"),
    ("\tfastcgi_param HTTP_AUTHORIZATION topsecretvalue;", "topsecretvalue"),
    ("      set $api_key abc123SECRET;", "abc123SECRET"),
    ("    proxy_set_header Authorization Bearer abc123SECRET;", "abc123SECRET"),
]

# (line, substring that MUST still be visible)
VISIBLE = [
    ("proxy_pass http://127.0.0.1:3500;", "proxy_pass http://127.0.0.1:3500"),
    ("server_name api.storytimeapp.me;", "api.storytimeapp.me"),
    ("client_max_body_size 25m;", "25m"),
    ("proxy_read_timeout 3600s;", "3600s"),
    ("proxy_buffering off;", "off"),
    ("listen 443 ssl;", "443"),
    # The mid-statement masking above must not swallow these. Each one exists
    # because it is a plausible way to over-mask: a secret-ish word inside a
    # hostname or a path, a secret-ish token that is not a name at all, and a
    # second directive after the masked one on the same line.
    ("server_name auth.storytimeapp.me api.storytimeapp.me;", "api.storytimeapp.me"),
    ("location /auth { proxy_pass http://backend; }", "proxy_pass http://backend"),
    ("auth_basic_user_file /etc/nginx/.htpasswd;", "/etc/nginx/.htpasswd"),
    ("error_log /var/log/nginx/auth_error.log warn;", "warn"),
    ("set $api_key abc; proxy_pass http://x;", "proxy_pass http://x"),
    ("proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
     "$proxy_add_x_forwarded_for"),
    ("*/5 * * * * /usr/bin/certbot renew --quiet", "/usr/bin/certbot renew --quiet"),
    # Indented, for the same reason as the indented leak cases.
    ("    proxy_pass http://127.0.0.1:3500;", "proxy_pass http://127.0.0.1:3500"),
    ("    proxy_read_timeout 3600s;", "3600s"),
    ("    proxy_buffering off;", "off"),
    ("  server_name auth.storytimeapp.me api.storytimeapp.me;", "auth.storytimeapp.me api.storytimeapp.me"),
    ("  ssl_certificate_key /etc/letsencrypt/live/x/privkey.pem;",
     "/etc/letsencrypt/live/x/privkey.pem"),
]

# mask_stream: a quoted value may CONTINUE on the next line, and mask_text sees
# one line at a time. (text, must-be-absent list, must-be-present list)
STREAM_CASES = [
    ("multi-line quoted secret",
     'JWT_SECRET="first part\nsecond part"\nproxy_pass http://x;\n',
     ["second part"], ["proxy_pass http://x"]),
    ("three-line quoted secret",
     "API_KEY='aaa\nbbb\nccc'\nlisten 443 ssl;\n",
     ["aaa", "bbb", "ccc"], ["443"]),
    ("config after the closing quote is still masked-then-kept",
     'SECRET="aaa\nbbb" ; proxy_pass http://y;\n',
     ["aaa", "bbb"], ["proxy_pass http://y"]),
    # The other direction, and the reason continuation mode is gated on the line
    # actually being rewritten: an apostrophe in a comment must NOT blank the
    # rest of the file, even when the comment mentions something secret-ish.
    # A PEM private key is a multi-line value. mask_text only ever saw the BEGIN
    # line; the base64 body fell to LONG_TOKEN, which cannot match a 64-char
    # base64 line broken up by `+` and `/`. Two of these three body lines were
    # emitted verbatim before the fix.
    ("PEM body lines never reach the output",
     "ssl_certificate_key /etc/x/privkey.pem;\n"
     "-----BEGIN RSA PRIVATE KEY-----\n"
     "MIIEowIBAAKCAQEA1x/9abc+def/ghijklmnopqrstuvwxyz0123456789ABCDEFGH\n"
     "short+line/here==\n"
     "MIIEowIBAAKCAQEA1xabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL\n"
     "-----END RSA PRIVATE KEY-----\n"
     "proxy_pass http://127.0.0.1:3500;\n",
     ["MIIEowIBAAKCAQEA", "short+line/here"],
     ["<redacted: PRIVATE KEY BLOCK>", "proxy_pass http://127.0.0.1:3500"]),
    ("PEM block truncated at EOF is still suppressed",
     "-----BEGIN PRIVATE KEY-----\nMIIEow+abc/def==\n",
     ["MIIEow+abc/def"], ["<redacted: PRIVATE KEY BLOCK"]),
    ("apostrophe in a comment does not swallow the file",
     "# the token doesn't matter\nproxy_pass http://127.0.0.1:3500;\n"
     "client_max_body_size 25m;\n",
     [], ["proxy_pass http://127.0.0.1:3500", "25m"]),
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
    # An env* key holding a SCALAR directly, not a map. This goes through a
    # different branch of _walk than the container cases above, and it kept
    # leaking numbers/booleans after the container path was fixed.
    ("scalar env container: number masked",
     {"apps": [{"env_production": 123456}]}, "123456", None),
    ("scalar env container: boolean masked",
     {"apps": [{"env_staging": True}]}, "true", None),
    ("scalar env container: null becomes <null>",
     {"apps": [{"environment": None}]}, None, "<null>"),
    ("scalar env container: string masked",
     {"apps": [{"env": "a-string-secret"}]}, "a-string-secret", None),
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
    for label, text, absent_list, present_list in STREAM_CASES:
        out = redact.mask_stream(text)
        problems = [f"leaked {a!r}" for a in absent_list if a in out]
        problems += [f"lost {p!r}" for p in present_list if p not in out]
        if problems:
            print(f"FAIL stream {label}: {'; '.join(problems)} in {out!r}")
            failed += 1
        else:
            print(f"pass stream {label}")
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
          f"{len(STREAM_CASES)} stream cases, {len(PM2_CASES)} pm2 cases, "
          f"{failed} failed")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
