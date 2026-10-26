# Deploying from the shared Woodpecker server

Status: **draft, nothing here is enabled.** Phase 1 (this PR) only makes the
deploy roles *able* to trust Woodpecker, and adds nothing until two variables
are set. Phases 2 and 3 are the owner's runbook and the pipeline port below.
GitHub Actions (`build-and-deploy.yml`) stays the only deploy path until the
cutover checklist is done.

## Architecture

```
Bolt-Silverfox/storytime-*  --push/manual-->  ci.fateround.com (Woodpecker server,
                                               AWS 772641335580, eu-west-2, infra-shared)
                                                     | workflow label lane: heavy-storytime
                                                     v
                              spot agent (own ASG shared-spot-storytime-agents,
                              instance role shared-spot-agent-storytime, IMDS hop limit 2)
                                                     |  step container: amazon/aws-cli
                                                     |  sts:AssumeRole + ExternalId   (no stored keys)
                                                     v
              storytime account 772316781095, eu-west-1:  storytime-gha-deploy-<service>
                      ECR push (one repo) + ssm:SendCommand (tag-scoped) + poll
```

- Lanes: unlabelled workflows (lint, unit tests) run on the light agent;
  anything that builds an image, and every deploy, carries
  `labels: { lane: heavy-storytime }` and runs only on storytime's spot agents.
  The lane has its own group, role, budget (US$15/month, inside the shared
  US$25) so it cannot starve peapool's lane. Infra side: infra-shared
  (`modules/spot-lane`), prepared separately from this repo.
- No long-lived AWS keys exist anywhere. A step on the lane uses the *instance
  role* (reachable from containers because the lane's IMDS hop limit is 2) to
  call `sts:AssumeRole` on **one** `storytime-gha-deploy-<service>` role with
  that service's ExternalId. The instance role can assume nothing else.
- **Role chaining is not used.** The instance profile's credentials are not an
  assumed-role session, so the one assume-role call gets the role's full
  `max_session_duration` (7200 s); the 1-hour chaining cap does not apply. A step
  must therefore assume the deploy role *directly from the instance role*,
  never from another assumed role.
- The deploy roles' permissions are unchanged (this PR touches only who may
  assume them).

## Trust model: what changes, honestly

| | GitHub OIDC (today) | Woodpecker (this change) |
| --- | --- | --- |
| Who may assume | a token minted for `repo:Bolt-Silverfox/<repo>:ref:refs/heads/main` | any step that runs on the storytime lane **and** knows the service's ExternalId |
| Pinned code | `job_workflow_ref` = a reviewed, SHA-pinned reusable workflow | nothing: AWS cannot see which pipeline file ran |
| Branch | enumerated | nothing in AWS; enforced only in Woodpecker (event filters) |
| Who can use it | repo write + a merge to main + the pinned workflow | anyone who can edit a pipeline file in an activated repo **and** trigger it, i.e. repo write access |

The ExternalId is a guard against a confused deputy and a handle for rotation;
it is not a strong secret: it is visible in the role's trust policy to anyone
with `iam:GetRole` in 772316781095 and stored in Terraform state. The second
secret (Woodpecker's copy) is what a pipeline must be able to read.

So **repo write access equals deploy access** for an activated repo. Mitigations,
all on the Woodpecker side and all required before cutover:

1. Deploy pipelines run on the `manual` event only (`when: event: manual`), and
   nothing else triggers them: no push, tag, cron or pull-request deploys.
2. The ExternalId secret is scoped to **event `manual`** and **image
   `amazon/aws-cli`** in the secret's settings, so a push or PR pipeline, or a
   step using any other image, cannot read it. (Image matching is by name, not
   tag, and I have not verified how Woodpecker treats a secret with an image
   filter used by a plugin step; the phase 3 smoke test must prove a `push`
   pipeline cannot print it.)
3. Pull-request events never receive deploy secrets; fork PRs wait for approval
   (server setting `WOODPECKER_DEFAULT_APPROVAL_MODE=forks`); only
   billmal071 and Bolt-Silverfox repos can be activated.
4. Branch protection on `main` of the app repos and on `storytime-devops` stays;
   a pipeline file change is a code review.
5. Rotate the ExternalIds (below) after any change of who has write access, and
   on a schedule.
6. A step on the lane can also read the Woodpecker agent secret from SSM (the
   instance role needs it at boot) and shares the instance role with every other
   step. Treat every step on this lane as trusted-as-deploy. Do not run
   third-party code or untrusted PRs on it.

If you need GitHub's "only this pinned workflow on this branch" guarantee
back for production, keep the GitHub OIDC path as the production deployer and
use Woodpecker for CI only. That is a legitimate end state.

## What this PR adds (Terraform, `infra/github-oidc-deploy.tf`)

All additive; with the defaults below nothing in any plan changes
(`tests/infra/run-tests.sh` proves it: trust policies keep exactly the one OIDC
statement).

| Variable | Default | Meaning |
| --- | --- | --- |
| `woodpecker_agent_role_arns` | `[]` | the lane's instance role ARN (max 2: current + one being rotated in) |
| `woodpecker_external_ids` | `{}` (sensitive) | service => ExternalId; keys `api admin web waitlist-api waitlist-web`; at least 32 chars |
| `woodpecker_ecr_registry_cache` | `false` | optional `ecr:GetDownloadUrlForLayer` on the role's own repository (see below) |

When `woodpecker_agent_role_arns` is non-empty each of the five roles gets a
second trust statement `sts:AssumeRole` from those principals, only when
`sts:ExternalId` equals that service's value. A precondition fails the plan if
any service lacks an ExternalId (rather than silently granting nothing). The
`Federated` OIDC statement is untouched. The principal must exist at apply time
(apply infra-shared's lane first), and if the lane's instance role is ever
deleted and re-created the trust must be re-applied (IAM stores principals by
unique ID).

### ECR registry cache (optional, not enabled)

`build-and-deploy.yml` uses `type=gha`, which has no Woodpecker equivalent
(there is no GitHub Actions cache service). The replacement is BuildKit's
`type=registry` cache in the same ECR repository, e.g.
`cache-from=type=registry,ref=<repo>:buildcache` and `cache-to=...,mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true`.
Before turning `woodpecker_ecr_registry_cache` on:

- the role needs `ecr:GetDownloadUrlForLayer` (that is what the variable adds;
  note it lets the role read every layer of its repository);
- **the repository lifecycle policy must manage the cache tag first.** Cache
  manifests are images; they count toward `ecr_keep_last_images` (20) and would
  push real images out of that window. In `ecr.tf` add, *before* the existing
  "keep last N, tagStatus any" rule (which must stay last, ECR requires the
  `any` rule to have the highest priority number), a rule such as
  `selection = { tagStatus = "tagged", tagPrefixList = ["buildcache"], countType = "imageCountMoreThan", countNumber = 1 }`
  with `expire`, and move the existing rules down by one priority;
- I have not tested BuildKit-to-ECR registry cache against this repository.

## Owner runbook

Prerequisites: the infra-shared storytime lane is applied and
`infra/tofu staging output spot_storytime_role_arn` printed
`arn:aws:iam::772641335580:role/shared-spot-agent-storytime` (call it
`$LANE_ROLE`). Phases 1 and 2 change nothing about how storytime deploys today.

### Phase 1: trust (this PR merged first)

1. Generate one ExternalId per service and a tfvars file, never printing them
   (run in a shell, outside the repo checkout):

```sh
umask 077; mkdir -p ~/.config/storytime
for s in api admin web waitlist-api waitlist-web; do
  printf '%s=%s\n' "$s" "$(openssl rand -hex 32)"
done > ~/.config/storytime/woodpecker-external-ids.env
LANE_ROLE_ARN='arn:aws:iam::772641335580:role/shared-spot-agent-storytime' python3 - <<'PY'
import json, os
d = os.path.expanduser("~/.config/storytime/")
ids = dict(l.rstrip("\n").split("=", 1) for l in open(d + "woodpecker-external-ids.env") if "=" in l)
json.dump({"woodpecker_agent_role_arns": [os.environ["LANE_ROLE_ARN"]], "woodpecker_external_ids": ids},
          open(d + "woodpecker.tfvars.json", "w"))
PY
```

   Both files are secrets: keep them outside the checkout (`*.tfvars` is
   git-ignored here, `.tfvars.json` is not).
2. In the `shared` workspace (account 772316781095, as for the other role
   changes): `terraform plan -var-file=terraform.shared.tfvars -var-file=$HOME/.config/storytime/woodpecker.tfvars.json -out=wp.tfplan`.
   Expected: 5 `aws_iam_role.gha_deploy_pipeline` **updated in place** (trust
   policy only), nothing else. Anything else: stop. Apply it.
3. Verify, from a step later (phase 2 check) or by hand with the lane role.

### Phase 2: activate repos and secrets in Woodpecker (still no deploys)

1. Sign in at <https://ci.fateround.com> as billmal071. Repositories > Add
   repository, activate each of: `storytime_be` (api), `storytime-fe` (web),
   `storytime_superadmin` (admin), `storytime-waitlist-be` (waitlist-api),
   `storytime-waitlist-fe` (waitlist-web). (Allowed: `WOODPECKER_REPO_OWNERS`
   already lists Bolt-Silverfox.) In each repo's settings leave "Allow pull
   requests" on only if you want CI on PRs; set "Pipeline approval" to forks.
2. In each repo: Settings > Secrets > Add secret:

   | Repo | Secret **name** | Value comes from | Available at events | Images |
   | --- | --- | --- | --- | --- |
   | `storytime_be` | `aws_external_id` | the `api=` line | `manual` only | `amazon/aws-cli` |
   | `storytime-fe` | `aws_external_id` | `web=` | `manual` only | `amazon/aws-cli` |
   | `storytime_superadmin` | `aws_external_id` | `admin=` | `manual` only | `amazon/aws-cli` |
   | `storytime-waitlist-be` | `aws_external_id` | `waitlist-api=` | `manual` only | `amazon/aws-cli` |
   | `storytime-waitlist-fe` | `aws_external_id` | `waitlist-web=` | `manual` only | `amazon/aws-cli` |

   Copy a value without showing it, e.g.
   `grep '^api=' ~/.config/storytime/woodpecker-external-ids.env | cut -d= -f2- | tr -d '\n' | pbcopy`
   and paste into the UI. Do not put it in a `.woodpecker/*.yaml`. The role ARN
   (`arn:aws:iam::772316781095:role/storytime-gha-deploy-<service>`) is not a
   secret and lives in the pipeline file.
3. Rotation: generate a new value for one service, `terraform apply` with it,
   update that repo's secret. Between the two the deploy fails closed. (There is
   no overlap window per service; schedule it outside a deploy.)
4. Prove it before any real deploy: a manual pipeline on `storytime-waitlist-fe`
   with the single step in the sketch below (`sts assume-role` then
   `sts get-caller-identity`), expect `storytime-gha-deploy-waitlist-web`. Then
   prove the negatives: a `push` pipeline cannot read `aws_external_id`; a
   wrong ExternalId gets AccessDenied; the api repo's value does not work on the
   web role.

### Phase 3: pipelines, cutover, rollback

Pipelines are **not in this PR**. Port after phase 2 passes (below).

Cutover checklist (per service, `api` first, as the existing runbook says):

- [ ] phase 1 and 2 verified, including the negative tests;
- [ ] `.woodpecker/deploy.yaml` merged in the app repo, `dry_run` equivalent passes;
- [ ] one real manual deploy from Woodpecker of `api`, digest verified, health
      gate and smoke pass, then the other four one at a time;
- [ ] GitHub caller workflows left in place, unused, for one release;
- [ ] only then remove the `uses: ...build-and-deploy.yml` callers. The OIDC
      trust statement stays in place as the fallback path.

Rollback at any point: run the GitHub `workflow_dispatch` deploy as before (it
is untouched until the last step). To switch Woodpecker off entirely, set
`woodpecker_agent_role_arns = []` and apply (the trust statement disappears;
the pipelines then fail at assume-role), delete the secrets, deactivate the
repos. The OIDC statement never changed, so GitHub deploys work throughout.

## Phase 3 sketch: port of `build-and-deploy.yml`

**Not implemented, not tested, not enabled.** `.woodpecker/deploy.yaml` in each
app repo. Shape only; every item under "Open" must be settled in a spike before
this is real.

```yaml
# .woodpecker/deploy.yaml  (sketch)
when:
  - event: manual            # nothing else ever triggers a deploy
labels:
  lane: heavy-storytime      # the storytime spot agents (privileged buildx allowed here only)

variables:
  - &aws_cli amazon/aws-cli:2.37.10
  - &role arn:aws:iam::772316781095:role/storytime-gha-deploy-api   # per repo
  - &repo 772316781095.dkr.ecr.eu-west-1.amazonaws.com/storytime/api

steps:
  - name: assume-role           # instance role -> deploy role; credentials stay in the workspace
    image: *aws_cli
    environment:
      AWS_REGION: eu-west-1
      ROLE_ARN: *role
    secrets: [aws_external_id]
    commands:
      - aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name "wp-$CI_PIPELINE_NUMBER"
          --duration-seconds 7200 --external-id "$AWS_EXTERNAL_ID" --query Credentials > /woodpecker/aws-creds.json
      - 'echo "assumed: $(aws sts get-caller-identity --query Arn --output text)"'   # with the role's creds loaded from the file

  - name: ecr-login-and-resolve  # ECR password, instance lookup by tag (as "Resolve target instance")
    image: *aws_cli
    commands: [ ... ]

  - name: build-push             # buildx arm64, native on the arm64 spot agent
    image: woodpeckerci/plugin-docker-buildx:6.1.2   # the one tag the server allows privileged
    settings:
      repo: *repo
      tags: ${CI_COMMIT_SHA}
      platforms: linux/arm64
      provenance: false
      # cache_from / cache_to: type=registry,...  (see ECR registry cache)
      # registry auth: Open item 1

  - name: deploy                 # ssm send-command reconcile, poll, health gate, rollback
    image: *aws_cli
    commands: [ ... ]            # Open item 2

  - name: promote-and-smoke
    image: *aws_cli
    commands: [ ... ]
```

Mapping from the GitHub workflow:

| GitHub step | Woodpecker |
| --- | --- |
| `configure-aws-credentials` (OIDC, 7200 s) | `assume-role` above, 7200 s, direct from the instance role (no chaining) |
| Resolve target instance (tags) | same shell, `ec2 describe-instances` |
| Log in to ECR | `aws ecr get-login-password` |
| `build-push-action`, `type=gha` cache | buildx plugin on the heavy lane, `type=registry` cache or none |
| Check digest, Deploy on the instance, Promote latest, Post-deploy smoke | the same shell as today |

Open items (unverified, do not assume):

1. **ECR auth for the buildx plugin.** The plugin takes `username`/`password`
   settings, normally from a secret; the ECR password is generated at run time
   in an earlier step. Whether the plugin can read a docker `config.json` or
   password from the shared workspace is not verified. Spike it; the fallback is
   a throwaway ECR token written to a workspace docker config that the plugin is
   pointed at.
2. **The deploy step is ~450 lines of inline shell** in the reusable workflow
   (the SSM payload, health gate, rollback, `tests/deploy/run-tests.sh` extracts
   it from the YAML). Do not copy it. Move it to `scripts/deploy-on-instance.sh`
   in this repo in its own PR (and point the test harness at it), then have both
   the GitHub workflow and Woodpecker call it. How the Woodpecker step obtains
   it (clone this repo at a pinned SHA; whether the repo is readable from the
   lane without a token) is not settled.
3. **Passing assumed credentials between steps.** Each step is its own
   container; the sketch writes them to a workspace file. Alternative: an
   `~/.aws/config` profile with `credential_source = Ec2InstanceMetadata`,
   `role_arn` and `external_id` so each step assumes for itself (no file with
   credentials, but the ExternalId must then be present as a secret in every
   step that calls AWS).
4. **Secret image filter vs. the plugin.** The buildx plugin step has no secret
   today; the AWS steps all use `amazon/aws-cli`. If a step ever needs another
   image to see an AWS secret, widen the filter deliberately, not by dropping it.
5. **IMDS from a step container.** Relies on hop limit 2 on the Docker bridge
   network of the Woodpecker backend; unverified until the phase 2 test.
6. Manual-event inputs (service, environment, `dry_run`, `build_args`): Woodpecker
   manual pipelines accept variables; confirm the form in 3.18 before relying on it.
