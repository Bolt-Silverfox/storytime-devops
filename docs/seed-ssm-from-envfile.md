# Seeding SSM from the ENV_FILE secrets

Both production hosts are gone. Every service's real `.env` lived on those
boxes — but each app repo also holds it as a single opaque GitHub Actions
secret named `ENV_FILE`, and those survived:

| Repo | `ENV_FILE` last updated |
|---|---|
| `storytime_be` | 2026-08-19 |
| `storytime-fe` | 2026-07-16 |
| `storytime-waitlist-fe` | 2026-06-09 |
| `storytime_superadmin` | 2026-03-06 |
| `storytime-waitlist-be` | 2026-02-13 |

Every one of them is newer than the `.env` files left on the laptop, so they
are the authoritative recovery artifact, not a fallback.

The GitHub API will not return a secret's value — deliberately, and correctly.
So the values have to move machine-to-machine. That is all this workflow is:
a reusable workflow that reads `ENV_FILE` and writes each key to SSM as a
`SecureString`, with no path by which a value reaches a log, a transcript, or a
person.

## What stops the values leaking

- Every parsed value goes through `::add-mask::` **before** it is used for
  anything else, so even an unexpected traceback comes out redacted.
- No `set -x`, and no step echoes, cats or diffs a value. The only thing the
  job ever prints is the list of **key names**.
- Values reach the AWS CLI via `--cli-input-json` on a `0600` temp file, never
  as an argv element — argv is readable through `/proc` by anything else on the
  runner.
- The AWS role (`infra/github-oidc-ssm-seed.tf`) has `ssm:PutParameter` and
  nothing else. No `GetParameter`, no `GetParametersByPath`. A role that can
  write a secret but can never read one back is not an exfiltration path, even
  if the workflow itself is later compromised.
- **One role per repo**, each scoped to
  `parameter/storytime-<env>/<its service>/*` with the environment segment
  enumerated rather than wildcarded. A single shared role would let the waitlist
  front-end's `dev` branch overwrite `/storytime-prod/api/DATABASE_URL` — still
  not a read, but repointing a production database URL at someone else's host is
  exfiltration with extra steps, and four of the five repos are public. The
  enumeration matters for the same reason: an IAM `*` matches `/`, so
  `storytime-*/waitlist-web/*` would also match
  `/storytime-prod/api/waitlist-web/DATABASE_URL`, which the boot script reads
  recursively and reduces to `DATABASE_URL`.
- `role_arn` is caller-supplied, so the workflow rejects any ARN outside account
  `772316781095` before assuming it.
- `dry_run` defaults to `true`. The first run lists the keys and writes nothing.

## Read this before a non-dry run: it collides with Terraform

`infra/ssm-config.tf` manages parameters at
`/${local.prefix}/${service}/${key}`, and `local.prefix` is
`"${var.name_prefix}-${var.environment}"` — **byte-identical** to what this
workflow writes. Seeding a service whose keys Terraform also manages will
overwrite them out of band, flip a reviewed `String` into a `SecureString`, and
leave that workspace in permanent drift, with the next `terraform apply`
fighting the change back.

The seed is meant to run **first**, into an empty namespace, precisely because
we do not have the values to put in `secret_values`. So: for any service you
seed, leave `config_plain` and `secret_keys` empty for that service in the
tfvars until you have reconciled the key list this produces. Move keys into
Terraform deliberately, one at a time, after that.

## One-time setup

1. In the `shared` workspace, set `manage_github_ssm_seed_role = true` and
   apply. This reuses the OIDC provider FateRound already created — it does
   **not** flip `manage_github_oidc`, which must stay `false` in account
   `772316781095` (AWS allows one provider per URL per account).
   If the apply fails on `data "aws_kms_alias" "ssm"` with "no alias found":
   `alias/aws/ssm` is created lazily, on the region's first SecureString. Write
   one throwaway SecureString in eu-west-1 by hand, delete it, and re-apply.
2. Note the `gha_ssm_seed_role_arns` output — a **map**, repo name to role ARN.
   Each repo gets its own role and must use its own.
3. If a repo seeds from a branch other than the one recorded, change that
   entry's `ref` in `github_ssm_seed_repos` and re-apply. The refs are
   enumerated on purpose — `repo:Bolt-Silverfox/*` would let a fork's pull
   request assume a role that writes production configuration.

## Caller

Add this to each app repo as `.github/workflows/seed-ssm.yml`, on the repo's
**default branch** (that is the ref the OIDC subject is minted against):

```yaml
name: Seed SSM

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target stack
        required: true
        type: choice
        options: [dev, staging, blue, prod, all]
        default: all
      dry_run:
        description: List keys only, write nothing
        required: false
        type: boolean
        default: true

permissions:
  contents: read
  id-token: write

jobs:
  seed:
    uses: Bolt-Silverfox/storytime-devops/.github/workflows/seed-ssm-from-envfile.yml@main
    with:
      service: api                       # <-- per repo, see table below
      environment: ${{ inputs.environment }}
      role_arn: arn:aws:iam::772316781095:role/storytime-gha-ssm-seed-api  # per repo
      dry_run: ${{ inputs.dry_run }}
    secrets:
      ENV_FILE: ${{ secrets.ENV_FILE }}
```

`secrets: ENV_FILE:` must be passed explicitly — a reusable workflow inherits
nothing unless it is named, which is the behaviour you want here.

### MUST BE CONFIRMED ON THE FIRST DRY RUN: is `ENV_FILE` even visible here?

In four of the five repos `ENV_FILE` is an **environment** secret, not a
repository secret, so `${{ secrets.ENV_FILE }}` in the caller above may resolve
to an empty string unless the job is bound to the environment that holds it.
A job that calls a reusable workflow with `uses:` cannot carry an
`environment:` key of its own, so the binding cannot just be added to the
caller job. This is unverified — treat it as the first thing to check: **if the
dry run reports zero keys, this is why.** Two candidate remedies, neither yet
chosen: declare the environment on the job *inside* the reusable workflow, or
promote `ENV_FILE` to a repository secret for the duration of the seed and
delete it afterwards.

The `@main` on the `uses:` line is **load-bearing**, not a default. The role's
trust policy pins the OIDC `job_workflow_ref` claim to
`...seed-ssm-from-envfile.yml@refs/heads/main`, so a caller pointing at a tag,
a SHA or a branch gets `AccessDenied` on assume-role. If you need to test a
change on a branch, change `github_ssm_seed_workflow_ref` in the `shared`
workspace and apply — do not loosen the condition.

| Repo | `service` | Resulting path | Role |
|---|---|---|---|
| `storytime_be` | `api` | `/storytime-<env>/api/<KEY>` | `storytime-gha-ssm-seed-api` |
| `storytime-fe` | `web` | `/storytime-<env>/web/<KEY>` | `storytime-gha-ssm-seed-web` |
| `storytime_superadmin` | `admin` | `/storytime-<env>/admin/<KEY>` | `storytime-gha-ssm-seed-admin` |
| `storytime-waitlist-be` | `waitlist-api` | `/storytime-<env>/waitlist-api/<KEY>` | `storytime-gha-ssm-seed-waitlist-api` |
| `storytime-waitlist-fe` | `waitlist-web` | `/storytime-<env>/waitlist-web/<KEY>` | `storytime-gha-ssm-seed-waitlist-web` |

A repo's role can only write its own `service` segment, so passing the wrong
`service` fails with `AccessDenied` rather than clobbering another service.

These match the ECR repository names already created in the `shared` workspace.

## Running it

Run once per repo with `dry_run: true` and read the key list. It is the first
honest inventory of what production actually had — compare it against
`.env.example` and `src/shared/config/env.validation.ts`, both of which are
known to be incomplete. Then re-run with `dry_run: false`.

## Multi-line values do not survive the boot

The parser handles a PEM or a quoted-across-several-lines value correctly and
writes it to SSM intact — and then `infra/templates/user-data.sh.tftpl` throws
it away, because it builds a `docker --env-file` and that format cannot
represent a newline. It logs a WARN to cloud-init that nobody reads, and the
container starts without the key.

So the seed job flags them: any multi-line key is marked `<-- MULTI-LINE` in the
key list and repeated in a `::warning::`. Those keys must be stored
base64-encoded and decoded by the application — the `TLS_CERT_B64` /
`TLS_KEY_B64` convention in `ssm-config.tf` is the existing example. Deal with
them by hand after the seed; the workflow will not silently re-encode a value.

## How faithful the parsing is

Bytes between the quotes are stored as they appear in `ENV_FILE`. Two things
that implies, both deliberate:

- **No `\n` expansion.** node `dotenv` *does* expand `\n` inside double quotes.
  A Firebase-style `PRIVATE_KEY="-----BEGIN...\n..."` therefore reaches the app
  as a literal backslash-n where it used to arrive as real newlines. Expanding
  it instead would corrupt a service-account JSON, whose embedded `\n` must stay
  escaped to remain valid JSON — and since every value is masked, that
  corruption is invisible until production fails to boot. Check any key of this
  shape by hand.
- **No inline-comment stripping inside a value.** `JWT_SECRET=aB3 #kL9` keeps
  `#kL9`, because for an unquoted value there is no way to tell a comment from a
  password containing a hash — dotenv guesses (it stops at the `#`) and would
  silently truncate a password. Because this is a real divergence, any
  **unquoted** value containing a `#` is flagged `<-- CHECK: unquoted, contains
  #` in the key list and in a `::warning::`, so the dry run puts it in front of
  a person. A `#` inside a quoted value is not flagged — dotenv keeps that one
  too, so there is nothing to reconcile. Fix a flagged value by
  quoting the value in `ENV_FILE`, or in SSM by hand afterwards. A `#` comment
  *after* a closing quote is unambiguous and is dropped; any other trailing text
  fails the run.

Quoted values may use `'`, `"` or a backtick, as dotenv allows. Only double
quotes take backslash escapes, and those escapes are preserved, not resolved.

## Two things this deliberately does not do

**It does not sort secret from non-secret.** Everything is written as a
`SecureString`. Terraform's `ssm-config.tf` keeps a three-way split
(`config_plain` / `secret_keys` / `secret_values`) so that non-secret config is
reviewable in git; that split is worth making later, by hand, from the key list
this produces. Writing everything encrypted first is the safe order — a value
wrongly classified as plain is a disclosure, a value wrongly classified as
secret is only an inconvenience.

**It does not touch `NEXT_PUBLIC_*`.** Those are inlined at build time by
Next.js. Putting them in SSM for runtime injection produces blank strings in
the bundle. They have to be Docker **build args** in the ECR image build. They
will still be seeded here — harmlessly — but the image build is where they
actually have to be read.

## After seeding

`ENV_FILE` has now been copied into a system with real access control. What is
left behind is a second, unaudited copy of production credentials, and how
exposed it is depends on where it is stored. Verified on 2026-09-13: `ENV_FILE`
exists as an **environment** secret (`development` / `staging` / `production`)
in all five repos, and *additionally* as a **repository** secret in
`storytime_be` only. Every one of those environments has
`protection_rules: []`.

That distinction matters, because environment protection rules gate environment
secrets and nothing else. They do not apply to a repository secret. So
`storytime_be`'s repo-level `ENV_FILE` is readable by any workflow on any
branch no matter what protection rules are added to its environments later —
there is no rule that would fix it, and it simply has to be deleted. For the
other four, adding protection rules to `production` is genuinely worth doing
and closes the "any branch can declare `environment: production`" hole in the
meantime, but it is a stopgap: once the seed is verified, deleting `ENV_FILE`
is the actual fix everywhere.
