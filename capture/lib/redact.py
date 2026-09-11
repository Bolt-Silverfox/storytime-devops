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
#
# Every quoted alternative is ESCAPE-AWARE — `"(?:\\.|[^"\\])*"`, not `"[^"]*"`.
# With the simple form a backslash-escaped quote closed the value early:
# `SECRET="one \" two"` matched `"one \"` and left ` two"` on the line, i.e. the
# rest of a real secret. The alternatives start with distinct characters, so there
# is no ambiguity for the engine to backtrack over.
#
# An UNTERMINATED quote needs its own alternative, tried after the balanced pair
# and before the bare-token fallback. `JWT_SECRET="hunter2 with spaces` (no
# closing quote) matched neither quoted form, fell through to `[^\s;#,]+`, and
# emitted `JWT_SECRET=<redacted> with spaces` — the tail of a real secret, into
# an artefact meant to be committable. `"[^"]*$` consumes to end of line, which
# is the only safe reading: if the quote never closes, everything after it is
# part of the value.
KV_ANY = re.compile(
    r"""(?x)
    ([A-Za-z_$][A-Za-z0-9_.\-]*)
    (\s*[:=]\s*)
    ("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*$|'(?:\\.|[^'\\])*$|[^\s;#,]+)
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
    (?P<value>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*$|'(?:\\.|[^'\\])*$|[^\s;#]+)
    """
)

# Connection strings: keep the scheme and host, drop the credentials.
#
# The userinfo is `*`, not `+`. Requiring a non-empty username meant the
# password-only form matched NOTHING — and that form is the normal one for Redis,
# which has no username:
#   REDIS_URL=redis://:hunter2@localhost:6379
# `REDIS_URL` is not secret-ish by name either (no pass/secret/token/key in it),
# so nothing else looked at the line and the whole thing was emitted verbatim.
URL_CREDS = re.compile(r"(?i)\b([a-z][a-z0-9+.\-]*://)([^\s:@/]*)(:[^\s@/]*)?@")

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
QUOTED = re.compile(r"""(?x) "(?:\\.|[^"\\])*" | '(?:\\.|[^'\\])*' """)
JWT = re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b")
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
PEM_END = re.compile(r"-----END [A-Z ]*PRIVATE KEY-----")

# A secret-ish argument in the MIDDLE of a whitespace-separated statement, whose
# value is NOT quoted. This is the gap left by every grammar above, and it is a
# plain leak in both artefacts the `text` filter exists for:
#
#   proxy_set_header X-Api-Key abc123;      -> emitted VERBATIM
#   fastcgi_param HTTP_AUTHORIZATION tok;   -> emitted VERBATIM
#   add_header X-Webhook-Token wh_abc;      -> emitted VERBATIM
#   set $api_key abc123;                    -> emitted VERBATIM
#   */5 * * * * backup.sh --password pw     -> emitted VERBATIM
#
# ASSIGNMENT cannot see these: it matches `<directive> <second-token>` as
# name+value, judges it on the directive (`proxy_set_header`, not secret-ish) and
# then resumes AFTER the second token — so the real value is never even a
# candidate. The QUOTED sweep only fires on quoted strings, which is why
# `set $upstream_token "abc123";` was already caught and the unquoted twin was
# not. One character of quoting was the whole difference.
#
# Deliberately a token walk and NOT a regex substitution. The first attempt here
# was `re.sub` with a callback that returned the match unchanged when the name was
# not secret-ish — and returning a match still CONSUMES it, so on a realistically
# indented line the leading whitespace let the match start at the directive,
# swallow `X-Api-Key live_abc123`, and resume past the value: the exact bug being
# fixed, reintroduced by the fix. It passed the unit tests because they had no
# leading indentation. Every case below is therefore also asserted indented.
# Credential-bearing CLI flags whose NAME is not secret-ish on its own. `-u` /
# `--user` is the one that matters: `curl -u user:pass https://x` in a crontab
# passed every other test on this line. Deliberately short — `-p` is left out
# because it is `--port` at least as often as `--password`, and masking a port
# mapping out of a crontab costs real information for no privacy gain.
SECRET_FLAG = {"-u", "--user", "--username"}
_ARG_NAME = re.compile(r"-{0,2}[A-Za-z_$][A-Za-z0-9_$.\-]*")
_TOKEN = re.compile(r"\S+")


def _statement_end(text: str) -> int:
    """Index where the current statement stops, else len(text).

    Quote-aware, and `#` must be preceded by whitespace. Both are about not
    stopping INSIDE a credential:

      --user=admin:sekrit#suffix     -> `#suffix` was emitted as if it were a
                                        comment; it is part of the password.
      --user="admin:sekrit;suffix"   -> same, for a `;` inside a quoted value.

    An nginx statement still ends at its `;`, and a real trailing comment still
    ends it, because a comment is introduced by whitespace-then-`#`. A `#` with no
    space before it (a URL fragment, a password) is content, and treating it as
    content only ever extends masking.
    """
    quote = None
    for i, ch in enumerate(text):
        if quote is not None:
            if ch == quote and not _escaped(text, i):
                quote = None
            continue
        if ch in "\"'" and not _escaped(text, i):
            quote = ch
        elif ch == ";":
            return i
        elif ch == "#" and (i == 0 or text[i - 1] in " \t"):
            return i
    return len(text)


def _escaped(line: str, i: int) -> bool:
    """Is line[i] preceded by an ODD number of backslashes (i.e. escaped)?"""
    n = 0
    j = i - 1
    while j >= 0 and line[j] == "\\":
        n += 1
        j -= 1
    return n % 2 == 1


def _mask_secret_args(line: str) -> str:
    """Mask the value after a secret-ish, name-shaped argument token.

    Scope is kept narrow, because over-masking this file has regressed
    `proxy_pass` before. The candidate must be a WHOLE whitespace-delimited token
    that looks like a name (optionally `-`/`--` prefixed, no slashes, no `(`, no
    `=`), which is what keeps `/auth` in `location /auth { proxy_pass ...; }` and
    `($http_authorization` in `if ($http_authorization != "")` out of it.
    SAFE_DIRECTIVE still wins, so `proxy_pass http://127.0.0.1:3500;` is
    untouched, and a SAFE_LONG hostname is never treated as a name, so
    `server_name auth.storytimeapp.me api.storytimeapp.me;` keeps both hostnames.

    Masking runs to the end of the STATEMENT (`;`, `#` or end of line), not one
    token: `Authorization Bearer abc;` needs both tokens gone, and stopping at the
    first would leave `abc` on the line. `;` bounds it, so
    `set $api_key abc; proxy_pass http://x;` keeps its proxy_pass.
    """
    out = []
    pos = 0
    for m in _TOKEN.finditer(line):
        if m.start() < pos:
            continue
        tok = m.group(0)

        # `--user=admin:pw` carries its value INSIDE the token, so the
        # "mask what follows this token" path below skips it entirely: the token
        # compared against SECRET_FLAG was the whole `--user=admin:pw`, and
        # neither `user` nor the rest is secret-ish by the general rules.
        # (The `--token=abc` shape is already covered — KV_ANY sees `token=abc`
        # inside it — but `--user=` is not, which is the whole reason
        # SECRET_FLAG exists.)
        flag, sep, _inline = tok.partition("=")
        if sep and flag in SECRET_FLAG:
            cut = m.start() + len(flag) + 1
            stop = _statement_end(line[cut:])
            if any(c.isalnum() for c in line[cut:cut + stop]):
                out.append(line[pos:cut] + "<redacted>")
                pos = cut + stop
            continue

        name = tok.rstrip(";,")
        if not _ARG_NAME.fullmatch(name):
            continue
        if name not in SECRET_FLAG and (
            not _is_secretish(name.lstrip("-")) or SAFE_LONG.match(name)
        ):
            continue
        rest = line[m.end():]
        stop = _statement_end(rest)
        value = rest[:stop]
        gap = len(value) - len(value.lstrip(" \t"))
        # No separator means this token was not "<name> <value>" at all, and a
        # value with no alphanumeric is punctuation (`!=`, `""`), not a secret.
        if gap == 0 or not any(c.isalnum() for c in value):
            continue
        out.append(line[pos:m.end()] + value[:gap] + "<redacted>")
        pos = m.end() + stop
    out.append(line[pos:])
    return "".join(out)


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
    # Emit a marker only for the parts that were actually there, so
    # `redis://:pw@h` stays recognisably password-only rather than growing a user.
    line = URL_CREDS.sub(
        lambda m: (
            m.group(1)
            + ("<redacted:user>" if m.group(2) else "")
            + (":<redacted:pass>" if m.group(3) else "")
            + "@"
        ),
        line,
    )

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

    # Secret-ish argument mid-statement with an unquoted value. After the QUOTED
    # sweep, so a quoted value is already `<redacted>` here and this is a no-op.
    line = _mask_secret_args(line)

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
# Line-by-line masking is not enough on its own: a quoted value may CONTINUE on
# the next line, and `mask_text` sees one line at a time.
#
#   JWT_SECRET="first part
#   second part"
#
# The first line is masked correctly (the unterminated-quote alternative runs to
# end of line), and then `second part"` arrives as a line that mentions nothing
# secret-ish and matches no assignment grammar — so it is emitted VERBATIM. The
# tail of a secret, in an artefact meant to be committable. nginx accepts a
# newline inside a quoted string, so `nginx -T` really can produce this.
#
# `mask_stream` therefore carries one bit of state: which quote character we are
# inside. While inside, whole lines are replaced, up to and including the closing
# quote; the remainder of the closing line is masked normally.
#
# The entry condition is deliberately narrow, because the failure mode of getting
# it wrong is blanking a whole file: continuation mode starts ONLY when the line
# mentions something secret-ish AND has an unbalanced quote AND was actually
# rewritten by `mask_text`. A crontab comment like `# don't do this` has an
# unbalanced apostrophe and must not swallow everything after it — it mentions no
# secret, so it does not.
# If the closing quote never arrives, every remaining line is masked. That is
# deliberate: the alternative is guessing where a secret ends, and 99-WARNINGS.txt
# already tells the operator to read the artefact before committing it.


def _unbalanced_quote(line: str):
    """Return (quote character, index) for the quote left open, else (None, -1).

    A left-to-right scan rather than a regex: the regex form of this
    ("balanced pairs, then a lone quote") needs nested quantifiers and can
    backtrack quadratically on a long line with many quotes. One pass, no
    backtracking, and easier to audit — which matters more here than brevity.

    The quote must OPEN A VALUE — preceded by `=`, `:` or whitespace, or at the
    start of the line. Without that test an apostrophe inside a word qualified,
    and `# the token doesn't matter` (a line that mentions something secret-ish
    and does get rewritten) started continuation mode and blanked every following
    line to the end of the file. That is not a leak, but it is a capture that
    tells the operator nothing.
    """
    quote = None
    at = -1
    for i, ch in enumerate(line):
        if ch not in "\"'" or _escaped(line, i):
            # An ESCAPED quote is not a delimiter. Treating `\"` as one closed the
            # value early: `SECRET="one \" two` emitted ` two`, and the next line
            # of the value came out verbatim behind it.
            continue
        if quote is None:
            if i == 0 or line[i - 1] in "=: \t":
                quote, at = ch, i
        elif ch == quote:
            quote, at = None, -1
    return quote, at


def _find_unescaped(line: str, ch: str) -> int:
    """Index of the first UNESCAPED `ch` in line, or -1."""
    i = line.find(ch)
    while i != -1 and _escaped(line, i):
        i = line.find(ch, i + 1)
    return i


def _mask_line_and_quote(raw: str, strict: bool = False):
    """Mask one line and report the quote it leaves open, if any.

    Everything from an unterminated opening quote to end of line is part of the
    value, so it is CUT rather than masked piecewise. Without that, an unbalanced
    quote that mask_text's grammars did not own survived on the line:
    `JWT_SECRET=x other="ccc` kept `other="ccc`, and the tail of a closing line
    kept `"ccc`. QUOTED only matches balanced pairs, so it cannot help here.

    Both callers share this function deliberately. The remainder-of-a-closing-line
    path originally had its own copy of the entry test, cleared the state and never
    recomputed it, so

        SECRET="aaa
        bbb" PASSWORD="ccc
        ddd"

    left continuation mode on the middle line and emitted `ddd"` verbatim — the
    same tail-of-a-secret this exists to prevent, one branch over.

    `strict` is for that remainder: we already know the text carries the tail of a
    secret value, so every quoted string left on it is masked and an unbalanced
    quote continues without the line having to name something secret-ish itself.
    """
    masked = mask_text(raw)
    quote, at = _unbalanced_quote(raw)
    if strict:
        masked = QUOTED.sub("<redacted>", masked)
    elif quote is not None and (masked == raw or not _line_mentions_secret(raw)):
        # An apostrophe in a comment (`# don't do this`) must not start swallowing
        # the file, so an ordinary line has to have been rewritten AND mention
        # something secret-ish before its open quote is believed.
        quote = None
    if quote is None:
        return masked, None
    head = mask_text(raw[:at])
    if strict:
        head = QUOTED.sub("<redacted>", head)
    return head + "<redacted>", quote


def mask_stream(text: str) -> str:
    out = []
    pending = None
    in_pem = False
    for raw in text.splitlines():
        # A PEM private key is a MULTI-LINE value, and mask_text only ever saw the
        # BEGIN line. The base64 body was left to LONG_TOKEN, which matches
        # [A-Za-z0-9_-]{40,} — and base64 contains `+` and `/`, which break a
        # 64-character line into runs shorter than 40. Measured: of a three-line
        # body, two lines were emitted VERBATIM. Private key material, in an
        # artefact meant to be committable. Suppress from BEGIN to END instead.
        if in_pem:
            if PEM_END.search(raw):
                in_pem = False
            continue
        if PEM_BEGIN.search(raw):
            in_pem = True
            out.append("<redacted: PRIVATE KEY BLOCK>")
            continue
        if pending is not None:
            end = _find_unescaped(raw, pending)
            if end == -1:
                out.append("<redacted: continuation of a quoted value>")
                continue
            masked_tail, pending = _mask_line_and_quote(raw[end + 1:], strict=True)
            out.append("<redacted: continuation of a quoted value>" + masked_tail)
            continue
        masked, pending = _mask_line_and_quote(raw)
        out.append(masked)
    if in_pem:
        # EOF inside a key block: the END line never arrived. Say so rather than
        # leave the reader wondering whether the capture was truncated.
        out.append("<redacted: PRIVATE KEY BLOCK — no END line before end of input>")
    return "".join(line + "\n" for line in out)


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

# Command-line arguments are configuration values too, and `capture-host.sh` feeds
# `~/.pm2/dump.pm2` through this filter as well as `pm2 jlist`. dump.pm2 is FLAT —
# `args` sits at the top level of each app object, not inside `pm2_env` — so
# `"args": "--admin-token=SEKRIT"` was emitted verbatim while the identical value
# inside `pm2_env` was masked. A token on a command line is a token.
#
# The cost is that the flags themselves stop being readable, which is accepted:
# the KEY and the shape (a string, or a list of N items) still tell the reader an
# argument list exists and how long it is, and nothing in 30-pm2/summary.txt is
# built from it.
ARG_CONTAINER_RE = re.compile(r"^(node_|interpreter_)?args$", re.IGNORECASE)


def _mask_env_scalar(value):
    # The ONE scalar masker. There used to be a second, permissive one
    # (`_mask_scalar`) that passed numbers, booleans and None through on the
    # theory that they "carry no secret material". Both of its call sites turned
    # out to be leaks and were fixed one after the other, leaving it unused; it is
    # deleted rather than kept, because a spare permissive masker in this file is
    # a trap for the next edit. PM2's own bookkeeping keeps its real values
    # through the PM2_SAFE_KEYS allowlist in `_mask_env_value`, not by having a
    # masker that lets scalars past.
    #
    # A NON-STRING scalar is a candidate secret like any other:
    #   "env_production": {"OTP_SECRET": 123456, "LEGACY_PIN": 9876}
    # was emitted verbatim, because the values happen to be ints. A numeric OTP
    # seed, PIN or account id is exactly as sensitive as a string one.
    #
    # Cost, accepted deliberately: numeric PORT values in an env map now read
    # <set> rather than 3500. That is recoverable from the capture without any
    # secret exposure — 70-network/listening-sockets.txt records what is actually
    # bound, which is better evidence than what an env file claims anyway.
    #
    # null is kept as <null> rather than <set>: it cannot carry a secret, and
    # "explicitly null" vs "set to something" is a real distinction when
    # reconstructing config.
    if value is None:
        return "<null>"
    if isinstance(value, str):
        return "<empty>" if value == "" else "<set>"
    return "<set>"


def _mask_env_value(node, preserve_pm2_metadata: bool = False):
    """Mask a value found INSIDE an environment container.

    Fail-closed: every nested structure is masked too, rather than recursed into
    with `_walk`. Anything inside an env map is application configuration by
    definition, and `versioning` / `axm_options` style sub-objects can embed a
    token in a repository URL. Keys are always preserved — the NAMES are the
    entire point of the capture; only values are replaced.

    PM2_SAFE_KEYS is honoured ONLY at the top level of `pm2_env`, which is where
    PM2's own bookkeeping actually lives. Applying it at every depth leaked real
    configuration whenever an application happened to reuse one of those names:
    `"env_production": {"name": "..."}` emitted its value verbatim, because `name`
    is allowlisted. Nested env maps are pure application config, so nothing in
    them is exempt.
    """
    if isinstance(node, dict):
        return {
            k: (
                v
                if preserve_pm2_metadata
                and k in PM2_SAFE_KEYS
                and not isinstance(v, (dict, list))
                else _mask_env_value(v)
            )
            for k, v in node.items()
        }
    if isinstance(node, list):
        return [_mask_env_value(v) for v in node]
    return _mask_env_scalar(node)


def _walk(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if ARG_CONTAINER_RE.match(k):
                # Same contract as an env container, at any depth: names out,
                # values never.
                out[k] = (
                    _mask_env_value(v)
                    if isinstance(v, (dict, list))
                    else _mask_env_scalar(v)
                )
            elif ENV_CONTAINER_RE.match(k) and isinstance(v, (dict, list)):
                # PM2_SAFE_KEYS may be honoured ONLY inside `pm2_env`, which is the
                # single map carrying PM2's own bookkeeping (exec_mode, status,
                # pm_cwd — 30-pm2/summary.txt is built from them).
                #
                # ENV_CONTAINER_RE deliberately also matches `env`, `environment`
                # and the per-environment overrides `env_production`,
                # `env_staging`, `environment_*`. Those are pure APPLICATION
                # config: every value in them is a candidate secret, and none of
                # PM2's bookkeeping lives there. Passing preserve=True for them
                # meant any key that happens to collide with PM2_SAFE_KEYS was
                # emitted verbatim — `env_production: {"name": "…"}` came through
                # unmasked because `name` is allowlisted.
                out[k] = _mask_env_value(
                    v, preserve_pm2_metadata=(k.lower() == "pm2_env")
                )
            elif ENV_CONTAINER_RE.match(k):
                # An env key holding a scalar directly (`"env_production": 12345`)
                # rather than a map. Same contract as the dict/list branch above,
                # so it needs the same masker. This branch used to call a
                # permissive masker that passed numbers, booleans and None
                # through, so `env_production: 123456` and `env_staging: true`
                # survived here even after the container path was fixed.
                # Names out, values never — including this branch.
                out[k] = _mask_env_scalar(v)
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
        sys.stdout.write(mask_stream(text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
