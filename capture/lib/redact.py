#!/usr/bin/env python3
"""
Redaction filters for capture-host.sh.

DESIGN RULE, non-negotiable: this module NEVER emits a configuration VALUE.
Where a value matters it emits the marker `<set>` or `<empty>`, never the value
itself. If a filter cannot establish that its output is safe, it must fail rather
than emit — capture-host.sh treats a non-zero exit as "do not write this
artefact", so a broken redactor loses data instead of leaking it.

Filters (chosen with the first CLI argument):

  env-keys   stdin = a dotenv-style file        -> "KEY=<set>" / "KEY=<empty>"
  pm2-json   stdin = `pm2 jlist` / dump.pm2     -> same JSON, every env value masked
  text       stdin = arbitrary config text      -> heuristic secret masking
"""

import json
import re
import sys

# ---------------------------------------------------------------------------
# Heuristics for the `text` filter.
#
# Used for artefacts (nginx -T, crontabs) that are mostly non-secret but could
# contain a token someone pasted inline. This is a SAFETY NET, not a guarantee:
# 99-WARNINGS.txt tells the operator to read the output before committing it.
# ---------------------------------------------------------------------------

# Assignments whose NAME suggests a secret: mask the value, keep the name.
#
# NOTE ON WORD BOUNDARIES: this deliberately does NOT use \b around the keywords.
# `_` is a word character, so `\bsecret\b` does not match inside `JWT_SECRET`,
# `SECRET_KEY` or `REDIS_PASSWORD` — which is to say it missed most real
# environment-variable names. Substring matching over-matches occasionally
# (`author` contains `auth`), and that is the correct direction for a redactor:
# a needlessly masked value costs a re-read from the box, a missed one costs a
# credential in a public git history.
SECRETISH_NAME = re.compile(
    r"""(?ix)
        pass(word|wd)? | secret | token | api[_-]?key | apikey | private[_-]?key
      | access[_-]?key | client[_-]?secret | credential | bearer
      | dsn | sentry | webhook | signing | salt | passphrase | auth
    """
)

# Directive names that CONTAIN a secret-ish substring but are not secrets, and
# whose values must survive intact. `proxy_pass` is the single most important
# directive in the vhosts this filter exists to capture — masking its upstream
# would defeat the purpose of the capture. Keep this list tight and explicit.
SAFE_DIRECTIVE = re.compile(
    r"""(?ix) ^(?:
        (?:proxy|fastcgi|uwsgi|scgi|grpc|memcached)_pass
      | auth_basic(?:_user_file)?
      | auth_request(?:_set)?
      | auth_delay
      | auth_jwt_key_file
      | satisfy
    )$"""
)

# Any identifier on a line, including nginx `$variables`.
IDENTIFIER = re.compile(r"[A-Za-z_$][A-Za-z0-9_.\-]*")

# KEY=value / KEY: value anywhere on a line, so that `env REDIS_PASSWORD=x` is
# examined on REDIS_PASSWORD rather than on the leading `env` keyword.
#
# The value alternation must try a QUOTED string first, exactly as ASSIGNMENT
# does. With only `[^\s;#,]+` the value stopped at the first space, so a
# multi-word quoted secret was only partly masked and the rest of it stayed on
# the line: `JWT_SECRET = "hunter2 with spaces"` became
# `JWT_SECRET = <redacted> with spaces"`, and a passphrase came through as
# `PGPASSWORD=<redacted> secret <redacted> phrase'`. That violates this module's
# one hard rule — never emit a configuration value — and it is not recovered
# later, because the quoted-string sweep below can no longer see a balanced pair.
KV_ANY = re.compile(
    r"""(?x)
    ([A-Za-z_$][A-Za-z0-9_.\-]*)
    (\s*[:=]\s*)
    ("[^"]*"|'[^']*'|[^\s;#,]+)
    """
)


def _is_secretish(name: str) -> bool:
    return bool(SECRETISH_NAME.search(name)) and not SAFE_DIRECTIVE.match(name)


def _line_mentions_secret(line: str) -> bool:
    return any(_is_secretish(tok) for tok in IDENTIFIER.findall(line))


# name = value / name: value / name value  (nginx directives use whitespace)
ASSIGNMENT = re.compile(
    r"""(?x)
    (?P<name>[A-Za-z_][A-Za-z0-9_.\-]*)
    (?P<sep>\s*[:=]\s*|\s+)
    (?P<value>"[^"]*"|'[^']*'|[^\s;#]+)
    """
)

# Connection strings: keep the scheme and host, drop the credentials.
URL_CREDS = re.compile(r"(?i)\b([a-z][a-z0-9+.\-]*://)([^\s:@/]+)(:[^\s@/]*)?@")

# Long opaque blobs that are almost certainly key material.
LONG_TOKEN = re.compile(r"\b[A-Za-z0-9_\-]{40,}\b")

# High-confidence provider credential shapes, masked regardless of length. The
# length heuristic alone misses plenty of real credentials: an AWS access key id
# is exactly 20 characters, so `AKIA...` sailed straight through it.
KNOWN_SECRET = re.compile(
    r"""(?x)
      \b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b            # AWS access key id
    | \bgh[pousr]_[A-Za-z0-9]{16,}\b                     # GitHub token
    | \bgithub_pat_[A-Za-z0-9_]{20,}\b
    | \b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}\b     # Stripe-style
    | \bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}\b          # OpenAI / Anthropic
    | \bxox[baprs]-[A-Za-z0-9-]{10,}\b                   # Slack
    | \bAIza[0-9A-Za-z_\-]{30,}\b                        # Google API key
    | \bSG\.[A-Za-z0-9_\-]{16,}\b                        # SendGrid
    | \bglpat-[A-Za-z0-9_\-]{16,}\b                      # GitLab
    | \bnpm_[A-Za-z0-9]{30,}\b
    """
)

# Any quoted string on a line that ALSO mentions something secret-ish. This is
# what catches idioms the name=value grammar cannot see, e.g. nginx's
#   set $upstream_token "…";
# where the assignment's apparent "name" is the directive `set`, not the token.
QUOTED = re.compile(r"\"[^\"]*\"|'[^']*'")
JWT = re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b")
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")

# Known-safe long strings we do NOT want to mangle into uselessness.
SAFE_LONG = re.compile(
    r"""(?ix)
    ^(
        [A-Za-z0-9_\-]*(storytimeapp|amazonaws|cloudinary|googleapis)[A-Za-z0-9_.\-]*
      | (?:[A-Za-z0-9_\-]+\.)+[a-z]{2,}          # dotted hostnames
      | /[A-Za-z0-9_./\-]+                        # filesystem paths
    )$
    """
)


def mask_text(line: str) -> str:
    if PEM_BEGIN.search(line):
        return "<redacted: PRIVATE KEY BLOCK>"

    line = JWT.sub("<redacted:jwt>", line)
    line = KNOWN_SECRET.sub("<redacted:credential>", line)
    line = URL_CREDS.sub(lambda m: f"{m.group(1)}<redacted:user>:<redacted:pass>@", line)

    # KEY=value / KEY: value, judged on the KEY. Runs before the whitespace-separated
    # grammar below, which would otherwise treat a leading keyword (`env`, `set`,
    # `fastcgi_param`) as the name and never look at the real one.
    line = KV_ANY.sub(
        lambda m: f"{m.group(1)}{m.group(2)}<redacted>" if _is_secretish(m.group(1)) else m.group(0),
        line,
    )

    # If the line mentions a secret-ish identifier ANYWHERE, mask every quoted
    # string on it. This catches idioms the grammars cannot see, such as nginx's
    # `set $upstream_token "…";` where the apparent name is the directive `set`.
    # Over-masking is the correct direction for a safety net: a mangled directive
    # you have to re-read from the box beats a credential in a public git history.
    if _line_mentions_secret(line):
        line = QUOTED.sub("<redacted>", line)

    def _assign(m: "re.Match[str]") -> str:
        if _is_secretish(m.group("name")):
            return f"{m.group('name')}{m.group('sep')}<redacted>"
        return m.group(0)

    line = ASSIGNMENT.sub(_assign, line)

    def _long(m: "re.Match[str]") -> str:
        tok = m.group(0)
        return tok if SAFE_LONG.match(tok) else "<redacted:long-token>"

    return LONG_TOKEN.sub(_long, line)


# ---------------------------------------------------------------------------
# env-keys: the hard rule. Names out, values never.
# ---------------------------------------------------------------------------

def filter_env_keys(text: str) -> str:
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            # Not a KEY=VALUE line. Emit nothing rather than guess — an
            # unparsed line could be a continuation of a multi-line value.
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        value = value.strip().strip("\"'")
        out.append(f"{key}=" + ("<empty>" if value == "" else "<set>"))
    # Sorted + deduped so two captures of the same host diff cleanly.
    return "\n".join(sorted(set(out))) + ("\n" if out else "")


# ---------------------------------------------------------------------------
# pm2-json: `pm2 jlist` embeds the COMPLETE environment of every process, which
# on these boxes is every database URL, JWT secret and third-party API key on the
# platform. The structure is the valuable part, so keep it and mask every value.
# ---------------------------------------------------------------------------

# Keys inside an environment container that are PM2's OWN BOOKKEEPING — not
# application configuration — and are both safe and useful to keep verbatim.
# `30-pm2/summary.txt` is built from exec_mode, instances, status, restart_time
# and pm_cwd, so masking these would empty the most useful artefact in the capture.
#
# DELIBERATELY NOT LISTED: the inherited shell environment — PATH, PWD, HOME,
# SHELL, USER, LOGNAME, LANG, TERM, SHLVL, NODE_APP_INSTANCE, PM2_HOME and `_`.
# Those are environment variables, which is exactly the class this filter exists to
# mask, and `_` in particular holds the last command line — which can be an invocation
# carrying a token as an argument. They are now masked like anything else; only their
# NAMES survive, which is all the capture needs.
PM2_SAFE_KEYS = {
    "name", "namespace", "version", "exec_mode", "exec_interpreter",
    "instances", "pm_id", "pm_uptime", "created_at", "restart_time",
    "unstable_restarts", "status", "pm_cwd", "cwd", "pm_exec_path",
    "pm_out_log_path", "pm_err_log_path", "pm_pid_path",
    "max_memory_restart", "autorestart", "watch", "merge_logs", "vizion",
    "instance_var", "km_link", "unique_id", "windowsHide", "treekill",
    "kill_retry_time",
}

# Any key that is (or namespaces) an environment map. PM2 ecosystem files use
# `env`, and `env_production` / `env_staging` / `env_<anything>` for
# per-environment overrides, all of which land inside `pm2_env`. Matching only the
# literal names missed `env_production`, which leaked every value it contained.
# `pm2_env` is itself the process's environment map, so it must match too — and
# matching it is what routes its nested `versioning` / `axm_options` objects
# through the fail-closed masker rather than verbatim recursion.
ENV_CONTAINER_RE = re.compile(r"^(pm2_)?(env|environment)(_.+)?$", re.IGNORECASE)


def _mask_scalar(value):
    # Non-string scalars carry no secret material (ports, flags, counts, nulls).
    if isinstance(value, bool) or value is None or isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        return "<empty>" if value == "" else "<set>"
    return "<set>"


def _mask_env_value(node):
    """Mask a value found INSIDE an environment container.

    Fail-closed: every nested structure is masked too, rather than recursed into
    with `_walk`. Anything inside an env map is application configuration by
    definition, and `versioning` / `axm_options` style sub-objects can embed a
    token in a repository URL. Keys are always preserved — the NAMES are the
    entire point of the capture; only values are replaced.
    """
    if isinstance(node, dict):
        return {k: (v if k in PM2_SAFE_KEYS and not isinstance(v, (dict, list)) else _mask_env_value(v))
                for k, v in node.items()}
    if isinstance(node, list):
        return [_mask_env_value(v) for v in node]
    return _mask_scalar(node)


def _mask_env_dict(d: dict) -> dict:
    return _mask_env_value(d)


def _walk(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if ENV_CONTAINER_RE.match(k) and isinstance(v, (dict, list)):
                out[k] = _mask_env_value(v)
            elif ENV_CONTAINER_RE.match(k):
                # An env key holding a scalar: mask it rather than pass it through.
                out[k] = _mask_scalar(v)
            else:
                out[k] = _walk(v)
        return out
    if isinstance(node, list):
        return [_walk(v) for v in node]
    return node


def filter_pm2_json(text: str) -> str:
    # A parse failure must NOT fall through to emitting the raw input.
    data = json.loads(text)
    return json.dumps(_walk(data), indent=2, sort_keys=True) + "\n"


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"env-keys", "pm2-json", "text"}:
        sys.stderr.write("usage: redact.py {env-keys|pm2-json|text} < input\n")
        return 2

    mode = sys.argv[1]
    text = sys.stdin.read()

    if mode == "env-keys":
        sys.stdout.write(filter_env_keys(text))
    elif mode == "pm2-json":
        sys.stdout.write(filter_pm2_json(text))
    else:
        sys.stdout.write("".join(mask_text(l) + "\n" for l in text.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
