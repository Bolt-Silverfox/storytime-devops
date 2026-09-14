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

### Four of the five repos need `ENV_FILE` promoted for the run

`ENV_FILE` is an **environment** secret in all five repos, and a **repository**
secret additionally in `storytime_be` only. It is not present in every
environment — see the coverage table below — but wherever it does exist it is
environment-scoped. So in the other four, `${{ secrets.ENV_FILE }}` in the
caller above resolves to an empty string and the seed job fails with
`ENV_FILE parsed to zero usable keys` before it writes anything.

There is no way to pass an environment secret through `workflow_call`:

- A job that calls a reusable workflow with `uses:` cannot carry an
  `environment:` key of its own, so the caller job can never be bound to the
  environment that holds the secret.
- Putting `environment:` on the job *inside* the reusable workflow does not fix
  it. That selects an environment in **storytime-devops**, the called repo — not
  in the app repo whose secret we need. Worth naming, because it looks like it
  should work and it binds to the wrong place silently.
- Handing the value between jobs as a job **output** is not a workaround either.
  Outputs are not masked storage; that would write production credentials into
  the workflow run's metadata in clear.

The promotion cannot be done by hand, for the same reason this whole workflow
exists: GitHub will not give the value back to a person, only to a job. So it is
a one-off job in the app repo, bound to the environment, that copies the value
across without printing it. For `storytime-fe`, `storytime_superadmin`,
`storytime-waitlist-be` and `storytime-waitlist-fe`:

1. Add a temporary `workflow_dispatch` workflow on the repo's default branch
   with a single environment-bound job, and run it:

   ```yaml
   jobs:
     promote:
       runs-on: ubuntu-latest
       environment: production      # <-- the GitHub environment holding the
                                    #     ENV_FILE for the stack you are about
                                    #     to seed. `production` is right for the
                                    #     default `all` recovery run and for
                                    #     `prod`; it is wrong for `dev` and
                                    #     `staging`. Pick it from the pairing
                                    #     table below, deliberately.
       steps:
         - run: printenv ENV_FILE | gh secret set ENV_FILE --repo "$GITHUB_REPOSITORY"
           env:
             ENV_FILE: ${{ secrets.ENV_FILE }}
             GH_TOKEN: ${{ secrets.SEED_ADMIN_TOKEN }}
   ```

   `gh secret set` with no `--body` reads stdin, so the value is never an argv
   element, and it is encrypted with the repo's public key in transit. The
   default `GITHUB_TOKEN` cannot write Actions secrets, so `SEED_ADMIN_TOKEN` is
   a short-lived admin PAT with `secrets: write`, added just before this run.
2. Run the seed with `dry_run: true`, passing the `environment` input that
   **pairs with** the GitHub environment used in step 1, and check the key list.
3. Re-run with `dry_run: false`.
4. **Delete the repository-level `ENV_FILE` immediately** — plus the promote
   workflow and `SEED_ADMIN_TOKEN`, and revoke the PAT. Not at the end of the
   day, not after the next repo: as the last step of that repo's seed.

The two environments in steps 1 and 2 are **different namespaces that must be
chosen together**, and nothing in the workflow can check that you did. Step 1
names a GitHub *deployment environment* (which copy of `ENV_FILE` gets read);
step 2's `environment` input names a *Terraform stack* (which
`/storytime-<stack>/` prefix gets written). Promote from `production` and then
seed `dev` and you have written production credentials into the dev namespace,
with a green run and no warning. Pair them:

| Seed `environment` input | Promote from GitHub environment | Notes |
|---|---|---|
| `all` | `production` | The default single-stack layout, and the recovery case this document is written for. `terraform.all.tfvars.example` defines one `api` and one `web` at `NODE_ENV=production`, so `/storytime-all/` holds production values. Note that `variables.tf` describes `all` more loosely, as one box hosting every environment's containers side by side; if that layout is ever actually built, a single `/storytime-all/<service>/` namespace cannot hold dev and prod values at once and this row stops being true. |
| `prod` | `production` | Only if prod has been peeled off onto its own stack. |
| `staging` | `staging` | Not available in every repo — check the coverage table. |
| `blue` | n/a | `storytime_be` only, and that repo does not promote at all — it seeds from its repository-level copy. Not a faithful copy of blue either; see below. |
| `dev` | `development` | |
| `shared` | — | Account-global resources, no `ENV_FILE`. Do not seed it. The reusable workflow and the IAM policy both accept `shared`, but the caller snippet above deliberately does not offer it. |

`storytime_be` is the exception that still needs care: it skips promotion
entirely because it already carries a repository-level `ENV_FILE`, and a
repository secret has no source environment, so there is nothing to pair
against. Which stack's values that copy holds is not recorded anywhere —
confirm it with a `dry_run` key list before writing, and do not assume it
matches the `environment` you are seeding.

Seed one pair per run. If a repo needs values in two stacks, repeat the whole
promote / seed / delete cycle for each, rather than promoting once and seeding
twice — the repository-level copy must not outlive a single stack's run.

**The source environment does not always exist.** Verified 2026-09-13:

| Repo | `development` | `staging` | `production` |
|---|---|---|---|
| `storytime_be` | yes | yes | yes |
| `storytime-fe` | yes | yes | yes |
| `storytime_superadmin` | yes | yes | yes |
| `storytime-waitlist-be` | yes | **no** — the `staging` environment exists but holds no secrets at all | yes |
| `storytime-waitlist-fe` | yes | **no** — there is no `staging` environment | yes |

Promoting from an environment with no `ENV_FILE` yields an empty string and the
seed fails with `ENV_FILE parsed to zero usable keys`, which is the safe
outcome but a confusing one if you were not expecting it. Do not seed the
`staging` stack for the two waitlist repos until someone decides what their
staging configuration should be.

**`blue` is a `storytime_be`-only stack, and seeding it is not a faithful
copy.** Blue has no GitHub environment of its own: `blue-deploy.yml` binds to
`development` and builds blue's `.env` from green's `ENV_FILE` with a
substantial set of overrides — `PORT`, `DATABASE_URL` (a different database,
and its `connection_limit` query parameter capped), `REDIS_URL` (a separate
logical DB), `DEPLOYMENT_ENV`, and the whole `OTEL_*` / `GRAFANA_CLOUD_*`
block. That last group is the trap: green's
`ENV_FILE` carries no Grafana variables at all, and `GRAFANA_CLOUD_API_TOKEN`
is a repo-level secret in `storytime_be` injected by the workflow. So a `blue`
seed from `development` writes green's values and silently omits every
observability key. Reconcile the full override list against `blue-deploy.yml`
before treating a blue seed as complete — it is around a dozen keys, not
three.

Step 4 is not optional. A repository secret is readable by any workflow on any
branch, which is precisely the exposure the "After seeding" section below is
about. This procedure is only acceptable because it is a one-time recovery with
a deletion step attached, and not a pipeline anyone runs again.

The alternative we did not take: converting the reusable workflow into a
composite action would let an environment-bound job call it directly, secret and
all. But a composite action runs inside the caller's job, which changes the OIDC
`job_workflow_ref` claim, so every role's trust policy in
`infra/github-oidc-ssm-seed.tf` would have to be rewritten to match. That is a
lot of machinery to build for an operation that runs five times, once.

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
known to be incomplete. Then re-run with `dry_run: false`. For the four
environment-secret repos, that run is wrapped in the promote/delete steps above.

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
exists as an **environment** secret in all five repos — in `development` and
`production` everywhere, and in `staging` in `storytime_be`, `storytime-fe` and
`storytime_superadmin` only — and *additionally* as a **repository** secret in
`storytime_be` only. Every one of those environments has
`protection_rules: []`.

That distinction matters, because environment protection rules gate environment
secrets and nothing else. They do not apply to a repository secret. So
`storytime_be`'s repo-level `ENV_FILE` is readable by any workflow on any
branch no matter what protection rules are added to its environments later —
there is no rule that would fix it, and it simply has to be deleted. The same
applies to the temporary repository-level copies the seed procedure above
creates in the other four repos: delete each one as the last step of that repo's
seed, so it never outlives the run.

For the environment secrets that remain, adding protection rules to `production`
is genuinely worth doing and closes the "any branch can declare
`environment: production`" hole in the meantime, but it is a stopgap.

The end state is the same either way: no repository-level `ENV_FILE` in any of
the five repos, and — once the seeded values are verified in SSM **and every
consumer has been cut over** — no `ENV_FILE` at all.

### Seeding SSM is not the cutover — do not delete the environment secrets yet

Verified on 2026-09-13: all five repos still read `secrets.ENV_FILE` in their
deploy workflows, so deleting the environment-scoped secrets now breaks every
deployment. The consumers, on each repo's default branch:

| Repo | Workflows reading `ENV_FILE` | How it is consumed |
|---|---|---|
| `storytime_be` | `dev-deploy.yml`, `staging-deploy.yml`, `deploy-prod.yml`, `blue-deploy.yml` | `.env` written on the **runner**, used there for the build, then carried to the host by `rsync` (which does not exclude it) |
| `storytime-fe` | `deploy-dev.yml`, `deploy-staging.yml`, `deploy-prod.yml` | `> .env` before the build — `NEXT_PUBLIC_*` is inlined into the bundle |
| `storytime_superadmin` | `ci-cd.yml` (three jobs, bound to `development` / `staging` / `production`) | `.env` written per job, then `NEXT_PUBLIC_SENTRY_*` appended and the build run — build-time, like the other two front ends |
| `storytime-waitlist-be` | `dev.yml`, `prod.yml` | `> .env` for the running service |
| `storytime-waitlist-fe` | `deploy-frontend-dev.yml`, `deploy-frontend.yml` | `> .env` before the build |

So the deletion order is:

1. Seed, verify the key list, delete the temporary **repository-level** copy —
   as the last step of that repo's seed, per step 4 above. This is the urgent
   part and it does not depend on any cutover.
2. Migrate that repo's consumers. There are **three** distinct ones and only the
   first is solved by this work:
   - *Runtime, on the host.* `infra/templates/user-data.sh.tftpl` already reads
     the service's prefix from SSM recursively at boot. This is the case the
     seed exists for.
   - *Build time.* `NEXT_PUBLIC_*` is inlined into the bundle and cannot come
     from SSM at runtime at all (see the `NEXT_PUBLIC_*` note under "Two things
     this deliberately does not do" above). It has to become Docker build args
     in the ECR image build — a real change to all three front-end repos, not a
     config edit.
   - *On the CI runner.* All four `storytime_be` workflows write the `.env` on
     the **runner** and build there, so `ENV_FILE` is a build-time dependency
     in Actions regardless of where the app later runs. `dev-deploy.yml`,
     `staging-deploy.yml` and `deploy-prod.yml` go further and run
     `pnpm db:migrate:deploy` and `pnpm db:seed` on the runner too — the boot
     script cannot supply `DATABASE_URL` to a step running in Actions, so those
     need their own answer: an SSM read in the workflow under an appropriately
     scoped role, or migrations moved onto the host. `blue-deploy.yml` already
     does the latter (it migrates and seeds over SSH, reading the rsynced
     `.env` on the box) and is the closer model. Until this is settled,
     deleting `ENV_FILE` breaks the backend pipeline even if runtime is fully
     SSM-sourced.
3. Deploy each migrated repo once per environment and confirm it boots on the
   SSM-sourced values.
4. Only then delete that repo's environment-scoped `ENV_FILE`.

Steps 2-4 are per-repo and can lag; step 1 cannot. That lag is the reason to
add `production` protection rules now: for as long as the environment secrets
have to stay, those rules are the only control in front of them.
