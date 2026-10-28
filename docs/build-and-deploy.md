# Automated deploy to production

Until now there was **no automated path to production**. Merging to `main` in an
app repo ran tests and stopped. Every production image was built by hand on a
laptop and pushed to ECR with a person's own AWS credentials, so the running
artifact had no provenance, nobody could say which commit was live, and the one
laptop was a single point of failure.

This document describes the chain that replaces it, built for **one service
(`api`, from `storytime_be`)**. The other four are replications of the same two
pieces once this one has run green.

**It has not run yet.** The pieces are individually verified, and it is worth
being precise about what that did and did not cover:

- `terraform plan` clean in both affected workspaces; both plan-time
  preconditions deliberately tripped; `validate` and `fmt` clean.
- `actionlint` clean; every `run:` block passes `bash -n`.
- The remote payload was extracted by running the step's real `jq` program,
  concatenating the resulting `commands` array exactly as AWS-RunShellScript
  would, and checking that with `dash -n` — so the POSIX claim covers the
  script as shipped, not the heredoc in isolation.
- That same assembled payload was executed against stubbed `docker` and
  `systemctl` for nine cases: all replicas correct; a replica missing; all
  containers exited; all crash-looping; a stale digest; a **failing**
  `systemctl start` with healthy containers; a failing `systemctl start` with a
  missing replica; the service not present in `redeploy.sh` at all; and
  `redeploy.sh` itself absent. Only the first two (all-correct, and
  systemctl-fails-but-containers-fine) exit 0.
- The digest equivalence it depends on was tested against a real registry.
- The native arm64 runner was confirmed with a live probe job.

**Not covered:** the chain end to end, any `terraform apply`, real systemd job
coalescing under a concurrent reconcile, and whether the built image actually
serves traffic. It cannot execute until the Dockerfile lands (see Ordering,
next). Do not read "built" as "proven in production".

> **Update:** the chain below was written for the original reconcile-based
> workflow. It has since gained safety rails (immutable tags, single-service
> rollout, health gate with automatic rollback, an optional migration step, a box
> lock, and `:latest` promoted last). **Part 2 describes the current behaviour**;
> the paragraphs above record how the original verification was tested.

```
caller (workflow_dispatch) -> build-and-deploy.yml
  -> build linux/arm64, push :<full git SHA>
  -> ssm send-command (under the box lock): pull, [migrate], redeploy.sh <service> <sha>,
     health gate, auto-rollback on failure
  -> poll to a terminal state; fail the job if it failed
  -> promote :latest only after the gate passed
```

---

## Ordering — the pipeline is not usable yet

**There is nothing on `main` to build.** The production Dockerfile for the api
lives on `storytime_be` branch `chore/production-dockerfile` (commit `cff039b`),
which is **not merged anywhere and does not exist on the remote at all** — it is
local-only. The image currently running in production was built from it by hand.

So the order is:

1. Land the production Dockerfile on `storytime_be` `main` (its own PR — not
   this change).
2. Apply the Terraform here (`shared` workspace) to create the role.
3. Add the caller workflow below to `storytime_be`.
4. Merge to `main` and watch the first run.

Adding the caller before step 1 produces a red build on every merge, because
`docker build` has no Dockerfile to read.

---

## Part 1 — Terraform: the per-repo deploy role

`infra/github-oidc-deploy.tf`, gated behind `manage_github_deploy_roles`
(default **false**, so merging it changes nothing).

### Which workspace owns it, and why

**`shared`.** IAM role names are account-global. The `shared` workspace already
owns the account-global identity resources — the five `storytime-gha-ssm-seed-*`
roles — and the ECR repositories these policies name. Putting the roles in
`prod` instead would mean `staging` and `dev` each try to create the same role
name, and that surfaces as `EntityAlreadyExists` **part-way through an apply**,
after other resources have already changed, rather than at plan time. That
failure has already happened in this account once.

### What the role can do

One role per repo, named `storytime-gha-deploy-<service>`:

| Grant | Scope |
| --- | --- |
| `ecr:GetAuthorizationToken` | `*` — ECR has no resource-level permission for this call |
| push actions (AWS's documented push set) | **one** repository ARN, `<ecr_repository_prefix>/api` — `storytime/api` with the default prefix, never `storytime/*` |
| `ssm:SendCommand` | instances tagged `Stack=<github_deploy_target_stack>` **and** `Name=<stack>-app` (tag-scoped, survives instance replacement) |
| `ec2:DescribeInstances` | `*` — no resource-level permissions exist for it; read-only; lets the workflow find the instance by tag when `instance_id` is not passed |
| `ssm:SendCommand` | **one** document, `AWS-RunShellScript` |
| `ssm:GetCommandInvocation` | `*` — supports no resource types or condition keys, so this genuinely reads *any* Run Command output in the account. `ssm:ListCommandInvocations` is deliberately **not** granted. |

Trust is pinned on three OIDC claims: `aud`, an **enumerated** `sub`
(`repo:Bolt-Silverfox/storytime_be:ref:refs/heads/main`), and `job_workflow_ref`,
which pins the reusable workflow itself so that *any* other workflow on `main`
cannot assume the role.

The `sub` is never wildcarded. `repo:<org>/<repo>:*` would match every branch
and tag subject, every `environment:` subject, and `…:pull_request` for
**same-repo** pull requests — reducing the trust boundary to "anyone who can
push a branch". A fork-PR hole is possible too, but the trust policy deliberately does not
depend on settling that question: by default a fork `pull_request` run has its
token downgraded to read-only and `id-token` has no read level, so it cannot
mint a token — but that downgrade is conditional on the repo's "Send write
tokens to workflows from pull requests" setting, and `pull_request_target` gets
a read/write token regardless. Enumerating the ref makes both moot.

**Subject-format trap:** these are the classic `repo:OWNER/REPO:…` subjects,
which is what both repos emit today. GitHub's immutable format
(`repo:OWNER@ID/REPO@ID:…`) applies to repos created after 2026-07-15 *and to
any repo renamed or transferred after that date*. A rename or org move therefore
silently stops matching the trust policy, and every deploy then fails with a
bare STS `AccessDenied`. There is no clean API that reports which format a repo
is on — read the `sub` claim out of a failing run rather than trusting a
settings lookup — so if a deploy starts failing at assume-role right after a
rename, this is the first thing to check.

The OIDC **provider is a data source**, not a resource. `manage_github_oidc`
stays `false`: the FateRound stack already created the
`token.actions.githubusercontent.com` provider in account 772316781095, AWS
allows one per URL per account, and a second one fails the apply.

### Two operational traps

**The target is a tag match, not an ID.** The role lives in `shared`; the
instance lives in `prod`, and there is no state link. The SSM grant therefore
matches instances by tag (`Stack` and `Name`), so replacing the box (which
`compute.tf` does on a user-data or AMI change) does not break the deploy roles.
Callers can omit `instance_id` and let the workflow resolve it with
`ec2:DescribeInstances`.

**Deploys are scoped to one service.** The workflow runs
`redeploy.sh <service> <sha>`, which restarts only that service's containers.
(The box-wide `storytime-reconcile.service`, `redeploy.sh` with no arguments,
still runs at boot and restarts *everything* onto whatever each tag points at,
which is why `:latest` is only ever moved to an image that has passed the health
gate.)

### Plan

```bash
cd infra
terraform workspace select shared
terraform plan -var-file=terraform.shared.tfvars \
  -var 'manage_github_deploy_roles=true' \
  -var 'github_deploy_target_stack=storytime-prod'
```

Two plan-time preconditions guard the common mistakes: a `service` that is not a
key of `var.services` (the policy would name an ECR repository that does not
exist, and the failure would not appear until a push 404s in CI), and an empty
`github_deploy_target_stack` (the grant would match no instance and every deploy
would fail with an `AccessDenied` that looks like a policy bug).

To enable permanently, set in `terraform.shared.tfvars`:

```hcl
manage_github_deploy_roles = true
github_deploy_target_stack = "storytime-prod"
```

Then read the role ARN out of the `gha_deploy_pipeline_role_arns` output.

---

## Part 2 — The reusable workflow

`.github/workflows/build-and-deploy.yml` in this repo.

```
caller triggers (workflow_dispatch today; nothing here auto-triggers)
  -> resolve the box: instance_id override, else tag lookup, exactly one match
  -> build linux/arm64, push ONLY <acct>.dkr.ecr.<region>.amazonaws.com/storytime/<service>:<full git SHA>
  -> ssm send-command, run under  flock -w 1800 /run/lock/storytime-deploy.lock :
       1. pull the image BY DIGEST, check the :<sha> tag agrees, record the
          running image ref in /var/lib/storytime/deployed/<service>
       2. (api, run_migrations) one-off `prisma migrate deploy` from the NEW image
          -> a failure ABORTS here, before any container is replaced
       3. redeploy.sh <service> <sha>        (this service only)
       4. health gate: healthy + stable + on the pushed digest [+ smoke URL]
       5. any failure -> redeploy.sh <service> <previous>, wait healthy, job RED
  -> poll the SSM command to a terminal state, annotate the job from its exit code
  -> only then: move <service>:latest to the proven digest
```

### Inputs

Every input and secret an existing caller passes keeps working. All new inputs
are optional and their defaults preserve the old behaviour.

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `service`, `environment`, `role_arn` | yes | | unchanged |
| `instance_id` | **no** (was yes) | `''` | Override. Empty means: look the instance up by tag (`Stack=storytime-prod`, `Name=storytime-prod-app`, `running`) and fail unless **exactly one** matches. `prod` only. Needs `ec2:DescribeInstances` (see Terraform below). |
| `dry_run` | no | `false` | Build and push the `<sha>` tag, pull and verify on the box, run `prisma migrate status` (if `run_migrations`); replace nothing, move nothing. |
| `run_migrations` | no | `false` | api only (rejected for any other service). See *Migrations*. |
| `health_timeout_seconds` | no | `300` | How long the new container has to become healthy and stable; reused for the wait after a rollback. 60..900. |
| `health_stable_samples` | no | `6` | Consecutive healthy samples, 10 s apart, before the deploy counts as healthy. 2..30. `health_timeout_seconds` must be at least `10 x (this + 1)`. |
| `gate_smoke_url` | no | `''` | https URL curled **on the box** through the local proxy (`--resolve host:443:127.0.0.1`) as part of the gate. A failure rolls back. |
| `gate_smoke_expect_status` | no | `200,204,401,403` | Passing codes for `gate_smoke_url`. For `admin`, 401 is the meaningful pass. |
| `reconcile_timeout_seconds` | no | `2400` | Now a **floor**. The effective wait is the larger of this and `5460 + 2 x health_timeout_seconds + 300`. |
| `smoke_url`, `smoke_expect_status` | no | | unchanged: checked from the **runner after** the deploy; cannot roll back. Prefer `gate_smoke_url`. |

The two smoke inputs are deliberately separate: `smoke_url` predates the rails
and keeps its meaning for the callers that already use it; `gate_smoke_url` is
the one that participates in rollback.

### What the health gate requires

A deploy is healthy only when, for **every** container of the service (names
read from the box's own `redeploy.sh`, so replicas are covered), for
`health_stable_samples` consecutive samples:

- `State.Status` is `running` and `State.Restarting` is `false`;
- `RestartCount` has not changed since the first sample (a crash loop that
  Docker keeps restarting keeps resetting the count and times out);
- `State.Health.Status` is `healthy` (all five app images define a
  `HEALTHCHECK`; an image without one is treated as healthy-by-running);
- the container's image is the digest the build pushed (a swap that quietly did
  nothing is a failure, not a pass).

Then, if set, the smoke URL must answer one of the expected codes. Any failure
triggers the rollback; the loop is bounded by iterations, so it always ends.

### Exit codes and what the job says

| Box exit | Meaning | State of production |
| --- | --- | --- |
| `0` | deployed and healthy | new version |
| `1` | failed the gate and **rolled back** | previous version, healthy |
| `2` | failed and the rollback did **not** recover | **possibly down: act now** |
| `3` | aborted before any container was replaced (preflight, pull, digest mismatch, migration failure) | previous version untouched |
| `75` | could not get the deploy lock within 30 min | untouched |

`:latest` is moved only on `0`. After a `1` it still points at the previous,
good image, so a reboot or another service's deploy cannot pick up the bad one.

### Serialization

The payload runs as `flock -w 1800 -E 75 /run/lock/storytime-deploy.lock sh body`,
so deploys from different repos queue instead of racing (GitHub `concurrency:`
groups are per-repository and cannot do this). It exports
`STORYTIME_DEPLOY_LOCK_HELD=1` to the body.

**Not yet true on the box: `redeploy.sh` itself does not take this lock**, so a
manual `redeploy.sh` run, the boot-time reconcile unit, or an operator working
by hand is not serialised against a pipeline deploy. The follow-up (a
user-data/Terraform change, not part of this PR, not applied) is for
`redeploy.sh` to take the same lock unless `STORYTIME_DEPLOY_LOCK_HELD=1` is
set, which is why that variable is already exported. Until then: do not run
`redeploy.sh` by hand while a deploy is in flight.

### What `redeploy.sh` does that the rails rely on

Confirmed against the **live** box (see *Evidence*): `redeploy.sh <service> <tag>`
exists and restarts only that service; `redeploy.sh` pulls the image *before*
`docker rm -f`/`docker run`; and it ends with `docker image prune -af`, which
removes every image not backing a running container. Consequences:

- The superseded image is gone from the box moments after a successful swap, so
  **rollback re-pulls the previous image from ECR** by its tag. That is why the
  previous ref is recorded as a *tag*: the payload refuses to deploy (exit 3,
  before touching anything) over a container whose image is digest-pinned or
  lives in a different repository, since `redeploy.sh <service> <tag>` could not
  restore it. After a rollback it verifies the container is on the recorded
  previous digest.
- The image prune therefore happens inside `redeploy.sh`, not "after the
  health gate" as would be ideal. It cannot remove the image a running container
  uses, and rollback does not depend on the local copy, so this is safe; but it
  is a place where the pipeline does not fully control the order.
- Rollback depth is bounded by ECR retention (`ecr_keep_last_images`, default
  20, `tagStatus = any` in `infra/ecr.tf`).
- There is still a few seconds of downtime per swap (`docker rm -f` then
  `docker run`). This is rolling-risk reduction, not zero-downtime deploy.

### Migrations (`run_migrations: true`, api only)

Before the swap, from the **new** image (the old container lacks the new
migrations, so `docker exec` on it would be wrong):

```
docker run --rm --network storytime --env-file <0600 temp file> \
  <repo>@<digest> node_modules/.bin/prisma migrate deploy
```

The env-file is the running api container's environment minus what its image
bakes in, written `0600` under a `0700` directory on tmpfs and deleted by a
trap on every exit path. Output is tailed and every env value (and the userinfo
of URLs) is masked before it reaches the job log; if `python3` is missing the
output is suppressed rather than risked. A non-zero exit aborts with exit `3`,
**before any container is replaced**; the old containers keep serving.

Rules that the pipeline cannot enforce for you:

- Migrations run **forward only and are not undone by a rollback.** Roll the
  application back and the database stays on the new schema, so the *previous*
  version must tolerate the *new* schema. Write migrations expand/contract:
  add columns/tables first, deploy, and drop or rename in a later release.
- A migration that fails part-way may have applied earlier steps. Inspect the
  database before retrying.
- `dry_run` runs `migrate status`, which exits non-zero when migrations are
  pending; that is reported, not treated as a failure.

### How to deploy a hotfix

A hotfix is a normal deploy of a different commit; the rails stay on. Dispatch
the caller workflow from the hotfix commit (or merge it to the deploy branch and
dispatch). There is no "skip the gate" switch by design: if the gate is wrong
for an emergency, shorten `health_timeout_seconds` (minimum 60) rather than
bypassing it, but keep it at least `10 x (health_stable_samples + 1)` seconds
so the gate gets one warm-up sample before the stable ones. To rehearse first, dispatch with `dry_run: true`.

### Manual rollback

The pipeline rolls back by itself on a failed gate. To go back to an *older*
good build, or if the job reports exit `2`:

```bash
# 1. what does the box think is running / what was the previous image?
aws ssm send-command --region eu-west-1 --instance-ids <id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cat /var/lib/storytime/deployed/api","docker ps"]'
# 2. redeploy the service at a known-good immutable tag, under the deploy lock:
aws ssm send-command --region eu-west-1 --instance-ids <id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["flock -w 600 /run/lock/storytime-deploy.lock env STORYTIME_DEPLOY_LOCK_HELD=1 /usr/local/bin/redeploy.sh api <good-sha>"]'
```

`<good-sha>` is any tag still in ECR. Resolve `<id>` with
`aws ec2 describe-instances --filters Name=tag:Stack,Values=storytime-prod Name=tag:Name,Values=storytime-prod-app Name=instance-state-name,Values=running`.
**Do not** set `services.<name>.image_tag` and apply: it is interpolated into
user-data and `compute.tf` has `user_data_replace_on_change = true`, which
replaces the instance. A manual rollback does not move `:latest`; if the old
build should become `:latest` again, do that in ECR deliberately
(`aws ecr batch-get-image` + `put-image`), because the boot-time reconcile
starts whatever `:latest` points at.

### Kill switch and approval are caller-side

This workflow deliberately does neither. A job-level `environment:` inside a
reusable workflow resolves against **this** repo, not the caller, so approvals
cannot live here. When deploys later get an automatic trigger, the *caller*
workflow should carry them:

- **Approval:** a `deploy` job in the caller with `environment: production`
  (required reviewers on that environment) that `uses:` this workflow.
- **Kill switch:** a repository variable such as `DEPLOY_ENABLED` checked in the
  caller's `if:` (`if: vars.DEPLOY_ENABLED != 'false'`), so an incident stops
  merges from deploying without a code change. Manual `workflow_dispatch` can
  ignore it.
- `concurrency: { group: deploy-prod-<service>, cancel-in-progress: false }` in
  the caller, as before; cross-repo ordering is the box lock's job.

### Terraform changes this needs (code only; not applied by this PR)

`infra/github-oidc-deploy.tf`:

1. `ec2:DescribeInstances` on `*` (it has no resource-level permissions), for the
   tag lookup. Without it the lookup step fails fast with an actionable message
   and callers keep passing `instance_id`.
2. `github_deploy_workflow_ref` accepts a **list** of allowed workflow refs (a
   plain string still works). The trust condition is a `StringEquals` over the
   list, i.e. "any of". Each entry must be `...build-and-deploy.yml@<40-hex>`;
   branch refs are rejected.

### Bumping the workflow pin (the order matters)

`job_workflow_ref` is whatever the caller's `uses:` line says, and the OIDC trust
policy must list it. A change here only takes effect when callers re-pin, and a
mismatch fails assume-role. With the list, the sequence has no broken state:

1. Merge the change in this repo; note the merge commit SHA `N`.
2. `terraform apply` in `shared` with
   `github_deploy_workflow_ref = [<old>, <N>]` (and the `DescribeInstances`
   grant). Old callers keep working; new ones can start.
3. Re-pin one caller at a time to `@N`. Prove it on `waitlist-web` first (see
   *Rollout* below), then the rest.
4. When no caller uses `<old>`, apply `[<N>]` to drop the old SHA. Do not leave
   stale SHAs in the list: each one is privileged code that can still assume the
   role.

### Rollout to automatic deploys

1. Merge this PR (changes nothing for callers: they pin the old SHA).
2. Terraform apply (`shared`) with old **and** new SHA, plus `DescribeInstances`.
3. Re-pin callers to the new SHA, still `workflow_dispatch` only.
4. **Prove the rollback on `waitlist-web` with a deliberately unhealthy image**
   before trusting it: dispatch a build whose container fails its healthcheck
   (e.g. a build that exits or whose `/` returns 500) and confirm the job goes
   red, the box is back on the previous image, `:latest` did not move, and
   `/var/lib/storytime/deployed/waitlist-web` says `result=rolled-back`. Then a
   healthy dispatch, a `dry_run`, and (api) a `run_migrations` run against a
   migration that is known to fail.
5. Only then add the push trigger in the callers, behind the approval and kill
   switch above.

### Evidence and what is NOT proven

Confirmed read-only against the live prod box (`i-0d904f863b0161bcc`): the live
`/usr/local/bin/redeploy.sh` (164 lines) is, apart from the per-container
`run_service` lines, byte-identical to the template in
`infra/templates/user-data.sh.tftpl` once Terraform variables are substituted;
it takes `ONLY="${1:-}"` and `TAG_OVERRIDE="${2:-}"`; it ends in
`docker image prune -af`. The five app images define `HEALTHCHECK`s and all were
`healthy`; the entrypoint is `docker-entrypoint.sh` with `node_modules/.bin/prisma`
present in the api image; the `storytime` network exists; `/run/lock` exists and
`/var/lib/storytime` does not (the payload creates it).

`tests/deploy/run-tests.sh` runs the **real** step scripts and the assembled SSM
payload (under `sh` and `dash`) against stubs, for: success; unhealthy image ->
rollback; restart loop -> rollback; failed swap -> rollback; rollback that fails
(exit 2); migration success; migration failure -> abort before any swap; env-file
mode/cleanup and secret masking; dry run; smoke failure -> rollback; preflight
aborts; lock contention (give up with 75, and queue then proceed); instance
lookup (0/1/2 matches, access denied, override, non-prod); `:latest` promotion;
exit-code annotations; input validation. It runs in CI (`lint.yml`).

**Not proven, because it cannot be exercised on prod from here:** real Docker
healthcheck timing; real `prisma migrate` (including that
`docker-entrypoint.sh` passes the command through untouched, which was not
readable read-only); real SSM payload size/behaviour for the larger payload;
`flock` on the box (util-linux on AL2023; the harness uses the shim on macOS and
real flock in CI); `ecr put-image` for `:latest` (and OCI vs Docker manifest
types) against real ECR; the new IAM grant; that `curl --resolve` through Caddy
passes for each service's real route. These are what the `waitlist-web` rehearsal
in *Rollout* is for.

---

## Part 3 — Caller workflow for `storytime_be`

**This file is NOT installed by this change.** Copy it into `storytime_be` as
`.github/workflows/deploy-prod.yml` in a separate PR, *after* the production
Dockerfile has landed on `main` and the Terraform has been applied.

```yaml
name: Deploy to production

on:
  push:
    branches: [main]
  workflow_dispatch:

# Never let two deploys reconcile the same box at once: the second would fight
# the first over the same containers. `cancel-in-progress: false` because an
# in-flight deploy that has already pushed should finish its reconcile rather
# than leave the box half-updated.
concurrency:
  group: deploy-prod-api
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    uses: Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@e8e832285ca78d3c49bd54142d9b5aa4fc1ad0b0
    with:
      service: api
      environment: prod
      role_arn: arn:aws:iam::772316781095:role/storytime-gha-deploy-api
      # instance_id is optional once the role has ec2:DescribeInstances
      # (infra/github-oidc-deploy.tf); leave it out to use the tag lookup.
      # instance_id: i-0d904f863b0161bcc
      aws_region: eu-west-1
```

The ref is PINNED TO AN IMMUTABLE COMMIT, not `@main`. On a branch ref, anyone
who can push this repo's `main` can change privileged deploy code — code that
holds ECR push credentials and issues SSM commands to the production box —
without a change landing in any app repo.

**The SHA above is not decoration: it must equal `github_deploy_workflow_ref`
in `infra/github-oidc-deploy.tf` byte for byte**, because `job_workflow_ref` is
matched with `StringEquals` and the claim is whatever this `uses:` line says,
verbatim. That variable is the source of truth — copy the value from there
rather than from this page, which can only ever be a snapshot.

A mismatch fails **every** deploy at assume-role with `AccessDenied`, and it
surfaces at run time, not at plan. `github_deploy_workflow_ref` is a **list**, so
a pin bump no longer needs a broken in-between state; follow *Bumping the
workflow pin* in Part 2 (apply old + new, re-pin callers one at a time, then drop
the old one).

`permissions:` must be declared on the **calling** job as well. A reusable
workflow cannot grant itself more than the caller gave it, so without
`id-token: write` here the OIDC token is never minted and
`configure-aws-credentials` fails.

### Migrations

By default this chain still does **not** run migrations (`run_migrations`
defaults to `false`), which preserves the Dockerfile's deliberate design: 104
migrations must not race N restarting containers, and a failed migration should
not become a crash-loop. Setting `run_migrations: true` (api only) runs
`prisma migrate deploy` **once**, from the new image, in a one-off container
*before* the swap, and aborts the deploy if it fails. See *Migrations* in
Part 2 for the rules (forward-only; write expand/contract). The old manual
route was `docker exec -it api node_modules/.bin/prisma migrate deploy`
(the container is named `api`), which runs the *old* image's migrations and is
wrong after a deploy.

---

## Build architecture: do not emulate

The host is Graviton (`t4g`), so the image **must** be `linux/arm64`; an amd64
image dies with `exec format error`. Do not "solve" a slow build by building
amd64 — the box cannot execute it.

`ubuntu-latest` is amd64, so building there means QEMU user-mode emulation. This
image is close to a worst case for that: two full `pnpm install`s, two
`prisma generate`s, an `apt-get install build-essential`, a `nest build` and a
Python venv, all CPU-bound.

**The workflow therefore defaults to `runs-on: ubuntu-24.04-arm` — native arm64,
no emulation.** The QEMU step gates itself off via `runner.arch != 'ARM64'`.

### This is free here, and that was checked

GitHub's runner table lists `ubuntu-24.04-arm` under *Standard runners for
**public** repositories*, where use is "free and unlimited". Bolt-Silverfox is
on the **free** plan and both `storytime-devops` and `storytime_be` are
**public**, so the native runner costs nothing.

Verified empirically on 2026-09-16 rather than taken from the table: a probe job
pushed to a throwaway branch in this repo ran on `ubuntu-24.04-arm` and reported

```
aarch64
4            # nproc
15947 MB     # total RAM
arm64        # docker server arch
```

scheduling within seconds. (The probe branch was deleted afterwards.)

This matters because it inverts the usual advice. Native arm64 is normally the
*expensive* option you fall back to when emulation proves too slow; on a free
plan with public repos it is simply the better option with no trade-off, and
emulation should never have been the default.

### Private repos: already relevant, not hypothetical

Arm64 runners are **not** free for private repositories, and `storytime_superadmin`
(the `admin` service) **is private today**. Its private-tier arm64 runner is also
**2 vCPU / 8 GB**, not the 4/16 measured on the public one — so the tradeoff
above is not the one that will apply when `admin` is onboarded. Decide that case
on its own numbers.

The emulated path is kept working for exactly this reason — pass
`runner: ubuntu-latest` and the QEMU step switches itself back on. If the emulated time is then unacceptable, the
next option is a **self-hosted arm64 runner**: native speed, no per-minute cost,
and it builds on the same architecture and libc the image will run on, which
this Dockerfile explicitly depends on (`binaryTargets = ["native"]` in
`schema.prisma`, plus bcrypt's glibc prebuild). It should not live on the
application box — a runner competing for RAM on a 2 GiB instance already near
its memory budget would cause exactly the OOM the memory guards exist to
prevent.

### Caching

Either way the workflow uses a GitHub Actions layer cache (`cache-from` /
`cache-to` `type=gha`, scoped per service) so only changed layers rebuild, plus
a 120-minute job timeout so a cold build is not killed mid-flight.
`ignore-error=true` on the export means a full or evicted cache downgrades to a
warning instead of failing a deploy that already built successfully.

### The measurement

The emulated path was measured, cold cache, against the actual api Dockerfile
(`storytime_be` `chore/production-dockerfile`, commit `cff039b`):

```
docker buildx build --platform linux/arm64 --no-cache .
  -> exit 0, 2435 s  (40 min 35 s)
  -> linux/arm64, 250 MB
```

on an **8-core / 31 GB x86_64** host. The five slowest layers account for most
of it:

| layer | time |
| --- | --- |
| `build`: `pnpm install --frozen-lockfile` (full dev tree) | 899.6 s |
| `build`: `prisma generate && nest build` | 585.5 s |
| `build`: `apt-get install build-essential python3` | 557.1 s |
| `prod-deps`: `pnpm install --frozen-lockfile --prod` | 375.7 s |
| `python-deps`: `apt-get install python3 python3-venv` | 282.0 s |

Every one of those is CPU-bound work being interpreted by QEMU.

**A GitHub `ubuntu-latest` runner is 4 cores / 16 GB — half the cores of the
machine that produced 40 minutes.** So the figure on CI would be *worse*, not
better; the honest expectation is somewhere north of an hour, which is why the
job timeout is 120 minutes. That is an unacceptable merge-to-live latency for a
routine backend change, and it is the reason the default runner is native arm64
rather than emulated.

Not measured: a warm-cache emulated rebuild, and the native `ubuntu-24.04-arm`
build of this image (which needs the Dockerfile on a branch CI can reach — see
Ordering above). The native figure should be compared against this one on the
first real run.
