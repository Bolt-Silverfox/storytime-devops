# Deploying from the shared Woodpecker server

Status: **the trust is LIVE; the Woodpecker pipelines are not.** The
`WoodpeckerStorytimeLane` trust statement (and `MaxSessionDuration` 7200) was
already applied by hand to all five `storytime-gha-deploy-*` roles in account
772316781095. This code is what brings the repository in sync with that live
state; with the two variables unset it renders nothing. **Read "Reconcile with
the already-applied state" before running any `tofu` command**: the Phase 1
runbook further down describes a first-time setup and would overwrite the live
ExternalIds. Phases 2 and 3 (repo activation, secrets, pipeline port) are not
done. GitHub Actions (`build-and-deploy.yml`) is still the only deploy path
until the cutover checklist is done.

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
| Branch | enumerated | nothing in AWS, and not enforced by the secret filters either (they match event and image, not branch); see mitigation 1 and its gap below |
| Who can use it | repo write + a merge to main + the pinned workflow | anyone who can edit a pipeline file in an activated repo **and** trigger it, i.e. repo write access |

The ExternalId is a guard against a confused deputy and a handle for rotation;
it is not a strong secret: it is visible in the role's trust policy to anyone
with `iam:GetRole` in 772316781095 and stored in Terraform state. The second
secret (Woodpecker's copy) is what a pipeline must be able to read.

So **repo write access equals deploy access** for an activated repo. The
Woodpecker-side controls below are the intended ones. **None of them is in place
yet** (no repo is activated, no secret exists), and several are unverified
Woodpecker behaviour: confirm each on the server before relying on it.

1. Deploy pipelines run on the `manual` event only (`when: event: manual`), and
   nothing else triggers them: no push, tag, cron or pull-request deploys.
   **Gap:** this constrains what a *legitimate* pipeline file does, not what an
   author of a pipeline file can do. For a manual pipeline the pipeline config
   comes from the branch chosen at trigger time, and the secret filter works on
   event and image, not on branch. So anyone with write access who can push a
   branch containing their own `.woodpecker/*.yaml` can trigger it manually
   with `image: amazon/aws-cli` and read the ExternalId. (Unverified: confirm
   on the server whether a manual run of a non-default branch is possible for
   them.)
   **OWNER DECISION, not yet taken:** set the approval mode to `all_events`
   (every pipeline waits for a maintainer's approval), or put an equivalent
   second-person gate in front of manual runs, for these five repos. Until it
   is decided, do not describe pipeline file changes as "code reviewed".
2. The ExternalId secret is scoped to **event `manual`** and **image
   `amazon/aws-cli`** in the secret's settings, so a push or PR pipeline, or a
   step using any other image, cannot read it. (Image matching is by name, not
   tag, and I have not verified how Woodpecker treats a secret with an image
   filter used by a plugin step; the phase 3 smoke test must prove a `push`
   pipeline cannot print it.)
3. Pull-request events never receive deploy secrets (via the event filter in
   item 2); fork PRs wait for approval (server setting
   `WOODPECKER_DEFAULT_APPROVAL_MODE=forks`); only billmal071 and
   Bolt-Silverfox repos can be activated. Both are to be confirmed on the
   server.
4. Branch protection on `main` of the app repos and on `storytime-devops` stays.
   It protects `main`; it does **not** review a pipeline file on another
   branch that is run manually (see the gap in item 1).
5. Rotate the ExternalIds (below) after any change of who has write access, and
   on a schedule.
6. A step on the lane can also read the Woodpecker agent secret from SSM (the
   instance role needs it at boot) and shares the instance role with every other
   step. Treat every step on this lane as trusted-as-deploy. Do not run
   third-party code or untrusted PRs on it.
7. **The agent is global on a shared server.** The lane's agent is a *global*
   agent of the shared Woodpecker server (infra-shared
   `modules/spot-lane/main.tf:55`, label filter `!lane=heavy-storytime`), not
   an agent scoped to this organization. Any repo activated on that server, in
   any organization, whose pipeline sets `labels: lane: heavy-storytime` could
   be scheduled onto these instances and reach the instance role's
   credentials; the ExternalId, and nothing else, then stands between that
   step and these five roles. (Unverified: confirm on the server how label
   matching and repo/organization restrictions behave.) **Recommended:** an
   organization-scoped agent for Bolt-Silverfox, so that only Bolt-Silverfox
   repos can be scheduled there. **OWNER DECISION, not yet taken**, and it
   changes infra-shared, not this repository.

If you need GitHub's "only this pinned workflow on this branch" guarantee
back for production, keep the GitHub OIDC path as the production deployer and
use Woodpecker for CI only. That is a legitimate end state.

## What this PR adds (Terraform, `infra/github-oidc-deploy.tf`)

Additive; with the defaults below no role's trust document changes
(`tests/infra/run-tests.sh` proves it: trust policies keep exactly the one OIDC
statement). The one visible addition to a plan is the new output
`gha_deploy_trust_review` (below). The rendered policy JSON of the roles is
byte-identical to what the hand-applied roles carry.

**Plans redact the trust policy, and `gha_deploy_trust_review` is how you
review it.** The ExternalId is written into the role's trust policy, and marking
the variable `sensitive` does not survive `aws_iam_policy_document` (its rendered
`.json` is plain), so a plain diff of `assume_role_policy` would print it. The
role therefore sets `assume_role_policy = sensitive(...)`: `tofu plan` shows the
attribute as `(sensitive value)`. That also hides any change to the OIDC
statement, so the stack has a **non-sensitive output**,
`gha_deploy_trust_review` (repo => trust document, decoded), identical to the
rendered policy except that every ExternalId is replaced by
`sha256:<first 16 hex of sha256(id)>`. A plan shows a field-level diff of
principals, Sids, actions and the OIDC `aud` / `sub` / `job_workflow_ref` there,
and a rotation shows up as a changed `sha256:` marker. No ExternalId reaches
the plan, the saved plan's outputs or `tofu output`.

How to review a trust change in a plan:

1. Read the `Changes to Outputs:` block: every changed line of
   `gha_deploy_trust_review` is a real change to the trust document. For an
   OIDC change check the new `sub` (repo and branch) and each
   `job_workflow_ref` (`...build-and-deploy.yml@<40-hex>`, an SHA you have
   reviewed, no branch ref).
2. The five `aws_iam_role.gha_deploy_pipeline` entries may show
   `~ assume_role_policy = (sensitive value)`; that is the redacted twin of the
   same change and tells you nothing by itself. **If a role updates in place
   and `gha_deploy_trust_review` did not change, treat it as stop-and-
   investigate** (except the one-time marker case in "Reconcile" below, which
   is the very first plan after this lands).
3. `tests/infra/run-tests.sh` pins the default OIDC statement literally and
   proves the review output moves when the branch, the workflow SHA list or the
   repo set changes, and never contains an ExternalId.

(`tofu state show` / `tofu show` on the data source
`data.aws_iam_policy_document.gha_deploy_pipeline_assume[...]` *does* print the
ExternalId, because its `.json` is not sensitive. Do not run them where the
output is logged.)

What the review output cannot see: a change to the ExternalId that keeps the
same hash prefix (not a realistic collision), or anything outside the trust
document. It covers the same JSON the role is created with, so it cannot drift
from it.

| Variable | Default | Meaning |
| --- | --- | --- |
| `woodpecker_agent_role_arns` | `[]` | the lane's instance role ARN; only `role/shared-spot-agent-storytime` (optionally with a name suffix while rotating, role name at most 64 characters) in account 772641335580 (max 2: current + one being rotated in) |
| `woodpecker_external_ids` | `{}` (sensitive) | service => ExternalId; keys `api admin web waitlist-api waitlist-web`; 32 to 128 chars of `[A-Za-z0-9_+=,.@:/-]` |
| `woodpecker_ecr_registry_cache` | `false` | optional `ecr:GetDownloadUrlForLayer` on the role's own repository (see below) |

**ExternalId strength and the review hash.** `gha_deploy_trust_review` shows
each ExternalId as the first 16 hex characters (64 bits) of an unsalted
sha256. The hash is for **review only** (does it change); it is not a secret
store. Validation checks length and charset, not entropy, and deliberately does
not do more (it could reject the live values). So: every ExternalId must come
from `openssl rand -hex 32`, one per service. Never use a word, a name, an ARN,
a repo name or any value that already appears in the trust policy (e.g. the
role ARN or an OIDC `sub`): a guessable ExternalId can be confirmed offline
from a plan's hash, and an ExternalId equal to other text in the trust document
would be replaced, wherever that text occurs, by its own hash. The harness test
`review_weak_external_id_documented_behaviour` pins that behaviour.

The role-name regex on `woodpecker_agent_role_arns` is a **typo guard, not a
security boundary**: the real boundary is IAM (who can create or modify roles in
account 772641335580 and which role the ExternalId-conditioned statement
names). The regex stops an accidental `:root`, other account or wildcard from
being applied; it does not prove the named role is the lane's role.

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

### Reconcile with the already-applied state (do this FIRST)

The Woodpecker trust is already live (applied by hand in 772316781095). The
repository now carries the same code, so the goal of the first `tofu plan` is
to prove that state and code agree, **not** to change anything.

**Do NOT run "Phase 1" below as written.** Step 1 there generates *new*
ExternalIds (`openssl rand -hex 32`); applying a plan built from them would
overwrite the live ExternalIds on all five roles and silently break any
Woodpecker secret already set from the old values. Never regenerate. Reuse the
existing ones: the owner keeps them in
`~/.config/storytime/woodpecker.tfvars.json` (keys `woodpecker_agent_role_arns`
and `woodpecker_external_ids`; do not print or paste it). If that file is
missing, stop and ask the owner; recreating the values is a rotation, with a
deploy outage window, not a reconcile.

1. **Check the tfvars match what is live**, printing only a verdict per role:

   ```sh
   AWS_PROFILE=<read-only profile for 772316781095> AWS_REGION=eu-west-1 \
     scripts/check-woodpecker-external-ids.sh
   ```

   It calls only `aws iam get-role`, hashes the live ExternalId and the tfvars
   value, and prints `SAME`, `DIFFERENT`, `MISSING-LIVE` or `MISSING-TFVARS` per
   service; never a value or a hash. Exit 0 only when all five are `SAME`.
   (`tests/infra/check-external-ids-test.sh` covers it with fake data.) Anything
   but five `SAME`: stop. Do not plan or apply; find out which copy is right.
2. **Plan against the shared workspace with those tfvars** (OpenTofu, as
   everywhere below; the saved-plan warning in Phase 1 step 2 applies):

   ```sh
   cd infra && tofu workspace select shared
   tofu plan -var-file=terraform.shared.tfvars -var-file=$HOME/.config/storytime/woodpecker.tfvars.json -out=wp.tfplan
   ```

3. **What the plan should show.** Redaction hides the policy text, so the
   expectations are about the resource list:
   - `Changes to Outputs: + gha_deploy_trust_review = {...}` appears once (new
     output). Review it: five repos, each with the OIDC statement you expect
     and the `WoodpeckerStorytimeLane` statement from
     `role/shared-spot-agent-storytime` with `sha256:` markers. It is not an
     IAM change.
   - **State already carries the sensitive mark** on `assume_role_policy`
     (the hand-apply ran this code or equivalent): the roles show **no
     changes**.
   - **State does not carry the mark** (the hand-apply was done another way):
     the plan shows `~ assume_role_policy = (sensitive value)` as an in-place
     update on exactly the five `aws_iam_role.gha_deploy_pipeline` entries,
     and the plan prints a warning that includes the sentence **"The value is
     unchanged."**. That sentence is what distinguishes the marker-only case:
     present on all five roles => marker only; apply once, the next plan shows
     no role changes. A warning **without** that sentence, or a role update
     shown as a diff with no such warning, is **not** the marker case: stop
     and investigate.
   - **Any other update on a `gha_deploy_pipeline` role is stop-and-
     investigate**, as is any create/replace/destroy anywhere. Redaction makes
     a real difference in the ExternalId, a Sid, the principal or the OIDC
     statement look exactly like the harmless marker change above, so the
     redacted diff can never be taken as proof of "metadata only". Use step 1
     (ExternalIds) and the `gha_deploy_trust_review` diff (everything else) to
     tell them apart.
4. **Stop; do not apply unless the plan is clean or expected** (no role changes,
   or exactly the five marker updates above, plus the new output). Delete
   `wp.tfplan` afterwards; it is a secret.

Prerequisites (for a *fresh* setup only): the infra-shared storytime lane is applied and
`infra/tofu staging output spot_storytime_role_arn` (run from the infra-shared repository checkout's `infra/` wrapper directory, where the `tofu` helper script lives) printed
`arn:aws:iam::772641335580:role/shared-spot-agent-storytime` (call it
`$LANE_ROLE`). Reconcile and Phase 2 change nothing about how storytime deploys today.

### Phase 1: trust (first-time setup only; NOT for the current live state)

Skip this section: the trust is already applied. It is kept for rebuilding the
trust from scratch (new account or after a deliberate rotation of all five).
Its step 1 creates new ExternalIds.

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

   Both files are secrets: keep them outside the checkout. (`infra/.gitignore`
   ignores both `*.tfvars` and `*.tfvars.json`, so an accidental copy into
   `infra/` will not be staged, but outside the checkout is still the rule.)
2. In the `shared` workspace (account 772316781095, as for the other role
   changes), using **OpenTofu**:

   ```sh
   cd infra
   tofu workspace select shared
   tofu plan -var-file=terraform.shared.tfvars -var-file=$HOME/.config/storytime/woodpecker.tfvars.json -out=wp.tfplan
   ```

   **`wp.tfplan` is a secret.** A saved plan holds the input variables and
   planned values in cleartext, ExternalIds included, even though the terminal
   output is redacted. Keep it outside any synced or shared folder, never upload
   it (CI artefacts, chat, tickets), and delete it right after
   `tofu apply wp.tfplan` (`shred -u` or `rm`). `.gitignore` does not protect a
   local copy.

   Use `tofu` for everything that touches state. Do not mix Terraform and
   OpenTofu on the shared S3 state: whichever writes last can bump the state
   format/version and lock the other out. (CI uses Terraform only for
   `fmt`/`validate`/`tflint`, with `-backend=false`, so it never touches state.)

   Expected on a fresh setup: 5 `aws_iam_role.gha_deploy_pipeline` **updated in
   place** (trust policy), nothing else, with the new trust visible in
   `gha_deploy_trust_review` (the role's own `assume_role_policy` shows
   `(sensitive value)`). Anything else: stop. Apply it.
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
   and paste into the UI. **The clipboard is not private:** clipboard managers
   and history tools (Raycast, Alfred, Paste, Maccy, Universal Clipboard to
   other devices) can keep the value after you paste it. Turn clipboard history
   off or exclude the terminal first, and overwrite the clipboard afterwards
   (`printf '' | pbcopy`). Do not put it in a `.woodpecker/*.yaml`. The role ARN
   (`arn:aws:iam::772316781095:role/storytime-gha-deploy-<service>`) is not a
   secret and lives in the pipeline file.
3. Rotation: generate a new value for one service, `tofu apply` with it,
   update that repo's secret. Between the two the deploy fails closed. (There is
   no overlap window per service; schedule it outside a deploy. **Follow-up:**
   `woodpecker_external_ids` is a `map(string)`, so a rotation cannot accept the
   old and new value at once. Moving to `map(list(string))` would give an
   overlap window but is an interface change against the live state, so it is
   deliberately not part of this PR.)
4. Prove it before any real deploy: a manual pipeline on `storytime-waitlist-fe`
   with the single `assume-role-check` step in the sketch below (profile
   assume, then `sts get-caller-identity`), expect `storytime-gha-deploy-waitlist-web`. Then
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
  - name: assume-role-check     # per-step profile: no credentials file in the shared workspace
    image: *aws_cli
    environment:
      AWS_REGION: eu-west-1
      AWS_CONFIG_FILE: /tmp/aws-config   # container-local, NOT under /woodpecker (the shared workspace)
      AWS_PROFILE: deploy
      ROLE_ARN: *role
    secrets: [aws_external_id]
    commands:
      # Every AWS step repeats these two lines, so each assumes the role for
      # itself and nothing with credentials is written where a later step (or a
      # later pipeline on a reused workspace) can read it. The ExternalId must
      # therefore be allowed to every AWS step (images filter stays amazon/aws-cli).
      - printf '[profile deploy]\nrole_arn = %s\ncredential_source = Ec2InstanceMetadata\nexternal_id = %s\nrole_session_name = wp-%s\nduration_seconds = 7200\n' "$ROLE_ARN" "$AWS_EXTERNAL_ID" "$CI_PIPELINE_NUMBER" > "$AWS_CONFIG_FILE"
      - 'echo "assumed: $(aws sts get-caller-identity --query Arn --output text)"'   # deploy role creds
      # DO NOT instead write the assume-role output to /woodpecker/*: that is the
      # workspace every later step mounts, and it would hold live credentials.

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
| `configure-aws-credentials` (OIDC, 7200 s) | a per-step profile (`assume-role-check` above), 7200 s, direct from the instance role (no chaining) |
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
   container. The sketch deliberately does NOT hand credentials between steps
   through the shared workspace (any later step, including a plugin image, could
   read them); each AWS step builds a container-local `AWS_CONFIG_FILE` profile
   with `credential_source = Ec2InstanceMetadata`, `role_arn` and `external_id`
   and assumes for itself. The cost is that the ExternalId secret is present in
   every step that calls AWS. `credential_source` with `duration_seconds` /
   `external_id` in a profile is unverified against this setup (see item 5); if
   it fails, the fallback is ONE step that does assume-role, resolve, deploy and
   promote in a single shell with the credentials only in that shell's
   environment.
4. **Secret image filter vs. the plugin.** The buildx plugin step has no secret
   today; the AWS steps all use `amazon/aws-cli`. If a step ever needs another
   image to see an AWS secret, widen the filter deliberately, not by dropping it.
5. **IMDS from a step container.** Relies on hop limit 2 on the Docker bridge
   network of the Woodpecker backend; unverified until the phase 2 test.
6. Manual-event inputs (service, environment, `dry_run`, `build_args`): Woodpecker
   manual pipelines accept variables; confirm the form in 3.18 before relying on it.
