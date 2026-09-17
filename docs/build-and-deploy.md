# Automated deploy to production

Until now there was **no automated path to production**. Merging to `main` in an
app repo ran tests and stopped. Every production image was built by hand on a
laptop and pushed to ECR with a person's own AWS credentials, so the running
artifact had no provenance, nobody could say which commit was live, and the one
laptop was a single point of failure.

This document describes the chain that replaces it, built for **one service
(`api`, from `storytime_be`)**. The other four are replications of the same two
pieces once this one has run green.

**It has not run yet.** The pieces are individually verified — Terraform plans
clean in both affected workspaces, the workflow passes actionlint and its shell
passes `bash -n` and `dash -n`, the remote payload is tested against stubbed
`docker`/`systemctl` for the pass / stale / half-failed / service-down cases,
the digest equivalence it depends on was tested against a real registry, and the
arm64 runner was confirmed with a live probe job — but the end-to-end chain
cannot execute until the Dockerfile lands (see Ordering, next). Do not read
"built" as "proven in production".

```
push/merge to main (app repo)
  -> reusable workflow: Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml
     -> build linux/arm64
     -> push <acct>.dkr.ecr.eu-west-1.amazonaws.com/storytime/<service>:latest
        and the same image as :<full git SHA>
     -> ssm send-command: systemctl start storytime-reconcile.service
     -> poll the command to a terminal state; fail the job if it failed
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
| push + read layers/manifests | **one** repository ARN, `storytime/api`, not `storytime/*` |
| `ssm:SendCommand` | **one** instance ARN, `i-07cce36e829161c03` |
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

**The instance ID is a cross-workspace coupling.** The role lives in `shared`;
the instance lives in `prod`. There is no state link, so the ID is passed by
hand. If the prod instance is ever **replaced** (`compute.tf` replaces it on a
user-data or AMI change), its ID changes and every deploy fails with
`AccessDenied` on `ssm:SendCommand` until `github_deploy_instance_id` is updated
and `shared` is re-applied. That is the price of "this role can only talk to
that one box"; the looser alternative is the `ssm:resourceTag/Project` condition
the older `gha_deploy_ssm` uses, which re-widens the grant to every environment.

**A reconcile bounces every container, not just the one you built.**
`storytime-reconcile.service` runs `/usr/local/bin/redeploy.sh` with no
arguments, and that script re-pulls and re-creates **every** service on the box
onto whatever its configured `image_tag` currently points at. Deploying the api
therefore also restarts `web`, `admin`, `waitlist-api` and `waitlist-web`. On a
single-box stack that is seconds of downtime, but it means a bad `latest` pushed
by any repo goes live the next time any repo deploys. `redeploy.sh` accepts a
service name as `$1` if per-service reconcile is ever needed.

### Plan

```bash
cd infra
terraform workspace select shared
terraform plan -var-file=terraform.shared.tfvars \
  -var 'manage_github_deploy_roles=true' \
  -var 'github_deploy_instance_id=i-07cce36e829161c03'
```

Two plan-time preconditions guard the common mistakes: a `service` that is not a
key of `var.services` (the policy would name an ECR repository that does not
exist, and the failure would not appear until a push 404s in CI), and an empty
`github_deploy_instance_id` (the grant would match no instance and every deploy
would fail with an `AccessDenied` that looks like a policy bug).

To enable permanently, set in `terraform.shared.tfvars`:

```hcl
manage_github_deploy_roles = true
github_deploy_instance_id  = "i-07cce36e829161c03"
```

Then read the role ARN out of the `gha_deploy_pipeline_role_arns` output.

---

## Part 2 — The reusable workflow

`.github/workflows/build-and-deploy.yml` in this repo.

Inputs: `service`, `environment`, `role_arn`, `instance_id`, and optionally
`aws_region`, `dockerfile`, `build_context`, `reconcile_timeout_seconds`.

`instance_id` is a required input beyond the four originally specified. It has
to be: the role's policy names one instance ARN, and the workflow cannot
discover the instance by tag because the role deliberately does **not** grant
`ec2:DescribeInstances`. Passing it explicitly also means the workflow and the
IAM policy state the same target, so a mismatch fails closed with `AccessDenied`
rather than deploying somewhere unexpected.

`environment` is an **audit label only**. It names the role session and the SSM
command comment. It is deliberately *not* a job-level `environment:`, because a
job-level `environment:` inside a *reusable* workflow resolves against **this**
repo, not the caller — it cannot gate a caller's deploy behind the caller's
approvals, which is the opposite of what it looks like it does.

### The verification is the point

The last step is not `send-command`. It is `send-command` followed by a poll of
`ssm:GetCommandInvocation` until a terminal status, failing the job on anything
other than `Success`. A fire-and-forget `SendCommand` returns a CommandId
immediately and the job goes green whether or not the box ever pulled the image,
which is indistinguishable from a working deploy until someone notices
production is on last week's code.

**But polling an exit status is still not sufficient, and this is subtle.**
`systemctl start` on a `Type=oneshot` unit that is ALREADY RUNNING does not run
it again — systemd merges the request into the in-flight job and returns `0`
when that job completes. GitHub `concurrency:` groups are per-repository, so
they cannot serialise `storytime_be` against `storytime-fe`; both reconcile the
same box. Repo B's `systemctl start` would join repo A's run — a run that pulled
`latest` *before* repo B pushed — and report success having adopted nothing.

Scope that race honestly: the unit is `Type=oneshot` with no `RemainAfterExit`,
so it goes inactive the moment it finishes and a later `systemctl start` *does*
run it again. The window is only "while another reconcile is mid-flight" — but
that window is minutes wide, because it pulls images.

So the payload does not infer success from an exit status. It asserts the
observable end state on the box:

1. read the expected container count out of `/usr/local/bin/redeploy.sh`, which
   Terraform generates with one `run_service` line per container — so the number
   comes from the same apply that created them, with no second place to keep in
   step with `replicas`;
2. enumerate matching containers with `docker ps -a`, **not** `docker ps`;
3. require the count to equal the expected count, every one to be `running` and
   not `restarting`, and every one to be on exactly the digest just pushed.

Step 2 is the subtle one. `docker ps` lists only running containers, so with
`replicas = 2`, a deploy where `api-0` came up and `api-1` died would show one
container on the correct digest and nothing wrong — green, at half capacity.
Counting against the expected total is what makes "the box adopted this image"
mean all of it. It also catches the case where `redeploy.sh` is killed at
`TimeoutStartSec` after `docker rm -f` but before `docker run`, leaving the
service *down* rather than stale.

**What this still does not verify is that the image works.** A container can be
running on the right digest and failing every request. `var.services` carries a
`health_path` that nothing in this pipeline probes; a post-deploy health check is
the obvious next increment and is deliberately not in this change.

`aws ssm wait command-executed` is not used: its waiter caps at 20 attempts ×
5 s = 100 seconds, and a reconcile that pulls a fresh multi-hundred-MiB image
routinely exceeds that, so the waiter would report failure on a deploy that was
merely still running.

`systemctl start` on a `Type=oneshot` unit blocks until the unit finishes and
exits non-zero if it failed, so the shell status the SSM command reports is the
real reconcile result.

### Both tags come from one build

`latest` and `<git SHA>` are pushed from a single `build-push-action` invocation,
so they are byte-identical by construction rather than by two builds agreeing.
`latest` is what the box runs today (`redeploy.sh` pulls
`services.<name>.image_tag`, default `latest`); the SHA tag is the immutable
record that makes "which commit is in production" answerable, and is what the
reconcile verifies against.

### How to roll back — and how NOT to

**Do not set `services.<name>.image_tag` to a SHA and apply.** `image_tag` is
interpolated into the rendered user-data and `infra/compute.tf` sets
`user_data_replace_on_change = true`, so that **replaces the EC2 instance**,
taking every other container on it with it. `infra/README.md` already warns this
is "for shape changes, not routine deploys". It is also self-defeating here: the
replacement changes the instance ID, which breaks the deploy role's pinned
`ssm:SendCommand` ARN, so every subsequent deploy fails with `AccessDenied`
until `github_deploy_instance_id` is updated and `shared` is re-applied.

Roll back by re-pointing `latest` at the old manifest and reconciling — no
rebuild, no instance churn:

```bash
docker buildx imagetools create \
  -t 772316781095.dkr.ecr.eu-west-1.amazonaws.com/storytime/api:latest \
     772316781095.dkr.ecr.eu-west-1.amazonaws.com/storytime/api:<good-sha>
aws ssm send-command --instance-ids i-07cce36e829161c03 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl start storytime-reconcile.service"]'
```

Caveats, all of them load-bearing:

- `imagetools create` copies the manifest within the **same registry**; source
  and destination are both ECR here, so it is a server-side copy, not a pull and
  rebuild.
- The ECR repositories are `MUTABLE` precisely so `latest` can be moved
  (`infra/ecr.tf`). Do not flip them to `IMMUTABLE` — it breaks both the deploy
  and this rollback. A mutable repo can still carry per-tag mutability
  exclusions, so if a re-tag is ever refused, check those before assuming a
  permissions problem.
- **Rollback depth is bounded by retention.** `ecr_keep_last_images` defaults to
  20 with `tagStatus = any` (`infra/ecr.tf`), so an image roughly 20 deploys old
  has already been expired and there is nothing to re-point `latest` at. If you
  need a guaranteed rollback target further back than that, raise the retention
  or tag the release separately so it is not swept.

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
    uses: Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@main
    with:
      service: api
      environment: prod
      role_arn: arn:aws:iam::772316781095:role/storytime-gha-deploy-api
      instance_id: i-07cce36e829161c03
      aws_region: eu-west-1
```

`@main` must match `github_deploy_workflow_ref` in the Terraform exactly
(`...build-and-deploy.yml@refs/heads/main`), or the `job_workflow_ref` condition
rejects the assume-role.

`permissions:` must be declared on the **calling** job as well. A reusable
workflow cannot grant itself more than the caller gave it, so without
`id-token: write` here the OIDC token is never minted and
`configure-aws-credentials` fails.

### Migrations are not in this chain

The image ships the Prisma CLI, `schema.prisma` and all migrations, but nothing
in this pipeline runs `prisma migrate deploy`. That is the Dockerfile's
deliberate design — 104 migrations must not race N restarting containers, and a
failed migration should not become a crash-loop. Applying migrations stays a
separate, explicit step:

```
docker exec -it storytime-api node_modules/.bin/prisma migrate deploy
```

Automating it is a follow-up decision, not something to bolt onto a first
deploy.

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
