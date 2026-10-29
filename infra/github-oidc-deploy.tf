# ---------------------------------------------------------------------------
# Per-repo CI roles for the build-and-deploy pipeline.
#
# WHY THIS EXISTS
# There is currently NO automated path to production. Merging to `main` runs
# tests and stops; every production image so far was built by hand on a laptop
# and pushed to ECR with a personal AWS identity. That means the deployed
# artifact has no provenance, nobody can tell which commit is running, and the
# one person with the laptop is a single point of failure.
#
# This file grants the minimum an app repo's workflow needs to close that loop:
# push ONE service's image to ECR, and ask the box to reconcile its containers.
# Nothing else.
#
# WHY IT IS NOT THE gha_deploy ROLE (github-oidc.tf)
# That role is gated behind `manage_github_oidc`, which MUST STAY FALSE for
# account 772316781095 — the FateRound stack already created an OIDC provider
# for token.actions.githubusercontent.com there, AWS allows exactly one per URL
# per account, and a second one fails the apply. github-oidc.tf's own header
# documents the workaround, and github-oidc-ssm-seed.tf took it: look the
# existing provider up as a DATA source and reuse its ARN. This file does the
# same, so it can be enabled without flipping that flag.
#
# gha_deploy is also wrong on scope. It grants ECR push to
# `${ecr_repository_prefix}/*` and SSM SendCommand to every instance carrying
# the project tag — so one role could push the admin image into the api
# repository and redeploy production. The roles here are one per repo, each
# pinned to that repo's single ECR repository ARN and to one instance ID.
#
# WHICH WORKSPACE OWNS THIS
# `shared`, for the same reason it owns the ECR repositories and the five
# gha-ssm-seed roles: IAM role names are account-global. A role created in the
# `prod` workspace and again in `staging` is one name applied twice, and that
# surfaces as EntityAlreadyExists PART-WAY THROUGH an apply — after other
# resources have already changed — not at plan time. `shared` is also where the
# ECR repositories these policies name actually live, so the two stay in step.
#
# THE SSM TARGET IS SCOPED BY TAG, NOT BY INSTANCE ID.
# The roles live in `shared`; the EC2 instance they may SendCommand to lives in
# `prod`, and there is no state link between the two. This was previously an
# instance ID passed in by hand, which made "this role can only talk to that
# one box" exactly true — but compute.tf replaces the instance on any user-data
# or AMI change, and every replacement then broke all five deploy roles with
# AccessDenied until someone remembered to update the variable and re-apply
# `shared`. Instance churn is routine here, so that cost is not hypothetical.
#
# The tag condition below is NOT the weaker `ssm:resourceTag/Project` one that
# gha_deploy_ssm uses. Project spans environments, which is the objection that
# kept this pinned to an ID. This requires BOTH:
#
#   Stack = <github_deploy_target_stack>       e.g. storytime-prod
#   Name  = <github_deploy_target_stack>-app
#
# Stack is environment-specific, so a dev or staging box never matches, and
# Name pins it to the app instance rather than any future instance in the same
# stack. The grant is therefore "the app box of one named stack, whatever its
# current ID" — as tight as the ID pin in practice, and it survives
# replacement.
#
# Read the honesty note on SendCommandDocument below before widening this
# further: the role can run arbitrary root commands on whatever it matches.
# ---------------------------------------------------------------------------

variable "manage_github_deploy_roles" {
  description = <<-EOT
    Create the per-repo build-and-deploy CI roles (ECR push + SSM reconcile).
    Account-global — set this true in the `shared` workspace ONLY, or every
    workspace will fight over one set of role names.

    Like `manage_github_ssm_seed_role` and unlike `manage_github_oidc`, this is
    safe to turn on in account 772316781095: it CONSUMES the existing OIDC
    provider through a data source rather than creating a second one.

    Defaults false so merging this file changes nothing until someone opts in.
  EOT
  type        = bool
  default     = false
}

variable "github_deploy_target_stack" {
  description = <<-EOT
    The `Stack` tag of the environment a deploy may reconcile, e.g.
    "storytime-prod". The SSM grant matches by tag, so a replaced instance does
    not break every deploy role the way a pinned instance ID did.

    This is a CROSS-WORKSPACE value. These roles are created in `shared`, where
    local.prefix is the shared stack — so it cannot be derived and must name the
    target environment's stack explicitly.

    Scoped deliberately narrow: the policy requires Stack AND Name, so it
    matches one environment's app instance and not, say, a dev box that happens
    to carry the same Project tag.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.github_deploy_target_stack == "" || can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.github_deploy_target_stack))
    error_message = "github_deploy_target_stack must be a tag-safe lowercase name, e.g. storytime-prod."
  }
}

variable "github_deploy_repos" {
  description = <<-EOT
    One entry per app repo: the branch its deploy workflow runs on, and the
    single `service` whose ECR repository that repo may push to.

    ONE ROLE PER REPO, exactly as github_ssm_seed_repos argues. A shared role
    scoped to `storytime/*` would let the waitlist front-end's pipeline
    overwrite `storytime/api:latest`, and the reconcile that follows would put
    that image into production under the API's hostname. Scoping each role to
    one repository ARN makes that impossible rather than merely unlikely.

    `ref` is ENUMERATED, never wildcarded. `repo:Bolt-Silverfox/<repo>:*`
    matches every subject that repo can produce — every branch and tag, every
    `environment:` subject, and `repo:<org>/<repo>:pull_request` for SAME-REPO
    pull requests. That reduces the trust boundary to "anyone who can push a
    branch to this repo", which for a public repo with outside collaborators is
    materially weaker than "a merge landed on main".

    A fork-PR hole is ALSO possible, but do not rely on either direction of
    that argument. By default a `pull_request` run from a fork has its token
    permissions downgraded to read-only, and since `id-token` has no read
    level, such a run cannot mint an OIDC token — so by default the wildcard is
    dangerous for the same-repo reason above rather than for forks. But that
    downgrade is conditional on the repo-level "Send write tokens to workflows
    from pull requests" setting being OFF, and `pull_request_target` gets a
    read/write token regardless. Terraform cannot see either of those, so the
    trust policy must not depend on them: enumerate the ref and the question
    never arises.

    The subject is the CALLING repo's, not this one's: build-and-deploy.yml is
    a reusable workflow and GitHub mints the OIDC token against the caller.

    SUBJECT FORMAT HAS A MIGRATION TRAP. These values use the classic
    `repo:OWNER/REPO:ref:...` form, which is what both current repos emit.
    GitHub's immutable format (`repo:OWNER@ID/REPO@ID:ref:...`) applies to
    repos created after 2026-07-15 AND to any repo RENAMED or TRANSFERRED after
    that date. A rename of storytime_be, or a move between orgs, therefore
    silently stops matching this trust policy and every deploy fails with a
    bare STS AccessDenied. If that happens after a rename or transfer, the fix
    is to switch these values to the immutable form. (There is no known API
    that simply reports "is this repo on the immutable format"; the
    actions/oidc/customization/sub endpoint returns the customization template,
    not the format, so read the `sub` out of a failing run's token claims
    instead of trusting a settings lookup.)

    All five services are enumerated. This widened a deliberate
    storytime_be-only default, so the reasoning for changing it: creating a
    role is not deploying with it. These roles are inert until a caller
    workflow assumes one, every caller is `workflow_dispatch` only, and a
    deploy is therefore always a human running one service at a time. The
    original concern — "a broken deploy role that lands for five repos at once
    is five outages, not one" — is about deploys, and nothing here causes one.

    The intent behind it still holds, though, and is now an operational rule
    rather than a Terraform one: PROVE THE CHAIN ON `api` FIRST. Dispatch one
    api deploy, confirm the image reached ECR and the box reconciled onto the
    new digest, and only then dispatch the other four. If the trust policy or
    the OIDC subject format is wrong, that surfaces on the first dispatch and
    costs one service, not five.
  EOT
  type = map(object({
    ref     = string
    service = string
  }))

  # Same trap as github_ssm_seed_repos: the role name is derived from `service`
  # but the map is keyed by repo, so two repos sharing a service would produce
  # two roles with one name — an EntityAlreadyExists mid-apply instead of a
  # plan-time error. Catch it here.
  validation {
    condition     = length(distinct([for r in var.github_deploy_repos : r.service])) == length(var.github_deploy_repos)
    error_message = "Each repo must map to a distinct `service`; the role name is derived from it."
  }

  validation {
    condition     = alltrue([for r in var.github_deploy_repos : can(regex("^refs/heads/[A-Za-z0-9._/-]+$", r.ref))])
    error_message = "Each `ref` must be a full branch ref, e.g. refs/heads/main — a bare branch name never matches the OIDC `sub` claim."
  }

  default = {
    # One entry per app repo. `ref` is the branch a production deploy runs
    # from and is ENUMERATED, never wildcarded: `repo:Bolt-Silverfox/*` would
    # let any branch — or a pull_request_target run — assume a role that can
    # push a production image and reconcile the box.
    #
    # `service` must match a key in var.services; the role name is derived
    # from it, which is why the validation below requires them to be distinct.
    "storytime_be"          = { ref = "refs/heads/main", service = "api" }
    "storytime-fe"          = { ref = "refs/heads/main", service = "web" }
    "storytime_superadmin"  = { ref = "refs/heads/main", service = "admin" }
    "storytime-waitlist-be" = { ref = "refs/heads/main", service = "waitlist-api" }
    "storytime-waitlist-fe" = { ref = "refs/heads/main", service = "waitlist-web" }
  }
}

variable "github_deploy_workflow_ref" {
  description = <<-EOT
    The exact reusable workflow(s) permitted to assume a deploy role, as the OIDC
    `job_workflow_ref` claim spells it. Every caller's `uses:` line must match
    one of these strings VERBATIM or the assume-role fails with AccessDenied.

    A LIST of allowed refs (a single string is still accepted and treated as a
    one-element list, so existing tfvars keep working). The trust condition is
    StringEquals with several values, which IAM evaluates as "any of".

    WHY A LIST: bumping the pin used to be a hard lockstep -- apply the new SHA,
    then bump five callers -- with no state in between that works, so any
    in-flight or not-yet-bumped caller broke at assume-role. With a list the bump
    is: apply [old, new]; re-pin the callers one at a time; later apply [new]
    to drop the old one. See "Bumping the workflow pin" in
    docs/build-and-deploy.md.

    EACH ENTRY IS PINNED TO AN IMMUTABLE 40-HEX COMMIT rather than
    `@refs/heads/main`. On a branch ref, anyone who can push storytime-devops'
    main can change privileged deploy code -- code that holds ECR push
    credentials and issues SSM commands to the production box -- without a
    change landing in any app repo. Every entry here is a SHA that has been
    reviewed; do not leave a stale one in the list longer than the migration
    needs, because each listed SHA is a version of privileged code that can
    still assume the role.
  EOT
  type        = any
  default     = ["Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@e8e832285ca78d3c49bd54142d9b5aa4fc1ad0b0"]

  validation {
    condition = (
      can(tolist(var.github_deploy_workflow_ref)) || can(tostring(var.github_deploy_workflow_ref))
    )
    error_message = "github_deploy_workflow_ref must be a string or a list of strings."
  }

  validation {
    condition = (
      length(flatten([var.github_deploy_workflow_ref])) >= 1 &&
      length(flatten([var.github_deploy_workflow_ref])) <= 4 &&
      alltrue([
        for r in flatten([var.github_deploy_workflow_ref]) :
        can(regex("^Bolt-Silverfox/storytime-devops/\\.github/workflows/build-and-deploy\\.yml@[0-9a-f]{40}$", r))
      ])
    )
    error_message = "github_deploy_workflow_ref must hold 1 to 4 entries, each Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@<40-hex commit SHA>."
  }
}

variable "woodpecker_agent_role_arns" {
  description = <<-EOT
    IAM role ARNs (in the CI account, 772641335580) allowed to assume the
    per-service deploy roles from the shared Woodpecker server's storytime lane,
    i.e. the instance role of the `lane=heavy-storytime` spot agents
    (infra-shared: `shared-spot-agent-storytime`).

    EMPTY (the default) adds NOTHING: no second trust statement is rendered, so
    the roles' trust policies are byte-identical to the GitHub-OIDC-only form.

    When set, every deploy role gains a second statement:
    sts:AssumeRole by these principals ONLY when `sts:ExternalId` equals that
    service's value in var.woodpecker_external_ids. The Federated OIDC statement
    is not touched. See docs/woodpecker.md for the trust model and its limits.

    The principal must EXIST when this is applied (IAM rejects an unknown
    principal), so apply infra-shared's storytime lane first. IAM stores a role
    principal as its unique ID: if that role is ever deleted and re-created,
    re-apply this (taint the roles' trust, or change the list and back) or the
    trust silently stops matching.

    Role chaining is NOT used: the caller is an EC2 instance profile, not an
    assumed-role session, so the roles' max_session_duration (7200) applies in
    full to the one assume-role call a pipeline makes.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.woodpecker_agent_role_arns :
      can(regex("^arn:aws:iam::772641335580:role/shared-spot-agent-storytime[A-Za-z0-9+=,.@_-]*$", a))
    ])
    error_message = "woodpecker_agent_role_arns entries must be the storytime-lane agent role in the CI account 772641335580: arn:aws:iam::772641335580:role/shared-spot-agent-storytime (optionally with a name suffix while rotating). No other role, :root, :user, path or wildcard."
  }

  validation {
    condition     = length(var.woodpecker_agent_role_arns) <= 2
    error_message = "At most two Woodpecker agent roles (current plus one being rotated in)."
  }
}

variable "woodpecker_external_ids" {
  description = <<-EOT
    service => ExternalId required by the Woodpecker trust statement, keys among
    api, admin, web, waitlist-api, waitlist-web (the deploy roles' `service`).
    Generate each with `openssl rand -hex 32`; use a DIFFERENT value per service.

    SENSITIVE and passed via TF_VAR_woodpecker_external_ids or an untracked
    tfvars file, never committed. NOTE what that does and does not protect: the
    value is written into the role's trust policy (readable by anyone with
    iam:GetRole in this account) and sits in Terraform state. It is a
    confused-deputy guard and a per-service rotation handle, not a standalone
    secret. The pipeline's secret is the other copy.

    When woodpecker_agent_role_arns is non-empty, every deploy service must have
    an entry of at least 32 characters (a precondition fails the plan
    otherwise); a service without one would silently get no Woodpecker trust.
  EOT
  type        = map(string)
  sensitive   = true
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.woodpecker_external_ids) :
      contains(["api", "admin", "web", "waitlist-api", "waitlist-web"], k)
    ])
    error_message = "woodpecker_external_ids keys must be among api, admin, web, waitlist-api, waitlist-web."
  }

  validation {
    condition     = length(distinct(values(var.woodpecker_external_ids))) == length(values(var.woodpecker_external_ids))
    error_message = "Each service needs its own distinct ExternalId; do not reuse a value across services."
  }

  validation {
    condition = alltrue([
      for v in values(var.woodpecker_external_ids) : length(v) >= 32 && length(v) <= 128 && can(regex("^[A-Za-z0-9_+=,.@:/-]+$", v))
    ])
    error_message = "Each ExternalId must be 32 to 128 characters of [A-Za-z0-9_+=,.@:/-] (AWS's ExternalId charset; openssl rand -hex 32 gives 64)."
  }
}

variable "woodpecker_ecr_registry_cache" {
  description = <<-EOT
    OPTIONAL, default off. Grants the deploy roles ecr:GetDownloadUrlForLayer on
    their own repository so a BuildKit `type=registry` layer cache can be READ
    back (the push set already has BatchGetImage; the cache write path needs no
    more). The existing GitHub workflow uses type=gha and needs none of this.

    DO NOT turn it on before the repository's lifecycle policy has a rule for
    the cache tag: cache manifests are images, they count toward
    ecr_keep_last_images, and an unmanaged cache tag would push real images out
    of the keep-last window. See docs/woodpecker.md ("ECR registry cache").
    Note it also lets a role read every layer of its repository, which is why
    it is not granted by default.
  EOT
  type        = bool
  default     = false
}

locals {
  deploy_repos = var.manage_github_deploy_roles ? var.github_deploy_repos : {}

  # Normalised to a list whether the caller supplied a string or a list.
  deploy_workflow_refs = distinct(flatten([var.github_deploy_workflow_ref]))

  # repo => service, only for services that get the Woodpecker trust statement:
  # at least one agent role is configured AND the service has an ExternalId.
  # nonsensitive() reveals only the boolean "is there an entry", never the value;
  # without it the sensitive map would make the for_each below unusable.
  woodpecker_trust = {
    for repo, cfg in local.deploy_repos :
    repo => cfg.service
    if length(var.woodpecker_agent_role_arns) > 0 && nonsensitive(lookup(var.woodpecker_external_ids, cfg.service, "") != "")
  }

  # Built from the prefix rather than read off aws_ecr_repository.svc so this
  # file does not require the same workspace to also own ECR. The validation
  # below is what replaces the typo-catching a direct reference would have
  # given: a service that is not a key of var.services would otherwise produce
  # a policy naming a repository that does not exist, and the failure would not
  # appear until a push 404s in CI.
  deploy_ecr_repo_arns = {
    for repo, cfg in local.deploy_repos :
    repo => "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_prefix}/${cfg.service}"
  }
}

# Plan-time guard for the above. `terraform_data` with a failing precondition
# stops the apply before any IAM is touched, which is the same trick guards.tf
# uses for the memory budget.
resource "terraform_data" "github_deploy_guards" {
  count = var.manage_github_deploy_roles ? 1 : 0

  lifecycle {
    precondition {
      condition     = alltrue([for cfg in var.github_deploy_repos : contains(keys(var.services), cfg.service)])
      error_message = "Every github_deploy_repos service must be a key of var.services, so its ECR repository actually exists."
    }

    precondition {
      condition = (
        length(var.woodpecker_agent_role_arns) == 0 ||
        alltrue([for cfg in var.github_deploy_repos : nonsensitive(lookup(var.woodpecker_external_ids, cfg.service, "") != "")])
      )
      error_message = "woodpecker_agent_role_arns is set, so woodpecker_external_ids needs an entry for EVERY deploy service (api, admin, web, waitlist-api, waitlist-web); a service without one would get no Woodpecker trust at all."
    }

    precondition {
      condition     = var.github_deploy_target_stack != ""
      error_message = "github_deploy_target_stack must be set when manage_github_deploy_roles is true; otherwise the SSM grant matches no instance and every deploy fails with AccessDenied."
    }
  }
}

data "aws_iam_policy_document" "gha_deploy_pipeline_assume" {
  for_each = local.deploy_repos

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      # The provider this stack does NOT manage. Shared with the seed roles —
      # its count already covers both flags. Data source, not a resource: if it
      # is missing the plan fails loudly rather than silently creating a
      # duplicate and failing the account.
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Bolt-Silverfox/${each.key}:ref:${each.value.ref}"]
    }

    # `sub` alone authorises ANY workflow running on that branch — in a public
    # repo that is "anyone who can land a commit on main", plus every
    # third-party action already present in those workflows. job_workflow_ref
    # identifies the REUSABLE workflow being executed regardless of caller,
    # which is what makes "only the deploy workflow" true rather than a hope.
    #
    # Note what this does NOT constrain: the caller still controls the build
    # CONTEXT (the repo contents at that commit), so the image contents are
    # only as trustworthy as the branch. This pins which workflow may assume
    # the role, not what it may build.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.deploy_workflow_refs
    }
  }

  # SECOND, additive statement: the shared Woodpecker server's storytime lane.
  # Rendered only when var.woodpecker_agent_role_arns is non-empty and this
  # service has an ExternalId; otherwise the document is exactly the one above.
  #
  # What it binds, honestly: "a step running on the storytime lane (its instance
  # role) that knows this service's ExternalId". GitHub's statement binds repo +
  # branch + a SHA-pinned workflow; there is no equivalent claim here. The
  # mitigations are in Woodpecker (manual-event deploy pipeline, secrets scoped
  # to event=manual and the aws-cli image) -- see docs/woodpecker.md.
  #
  # One assume-role from instance-profile credentials: NOT role chaining, so
  # max_session_duration on the role applies in full.
  dynamic "statement" {
    for_each = contains(keys(local.woodpecker_trust), each.key) ? [1] : []

    content {
      sid     = "WoodpeckerStorytimeLane"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = var.woodpecker_agent_role_arns
      }

      condition {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.woodpecker_external_ids[each.value.service]]
      }
    }
  }
}

resource "aws_iam_role" "gha_deploy_pipeline" {
  for_each    = local.deploy_repos
  name        = "${var.name_prefix}-gha-deploy-${each.value.service}"
  description = "Builds ${each.key} and pushes ${var.ecr_repository_prefix}/${each.value.service}, then reconciles the app instance of ${var.github_deploy_target_stack}."
  # sensitive(): the Woodpecker statement embeds the ExternalId. Marking the
  # variable sensitive does NOT survive aws_iam_policy_document (the rendered
  # .json is not sensitive), so without this wrapper every plan that changes the
  # trust prints the ExternalId in plaintext. A side effect: the trust diff is
  # redacted in full, OIDC statement included; tests/infra pins that statement.
  assume_role_policy = sensitive(data.aws_iam_policy_document.gha_deploy_pipeline_assume[each.key].json)

  # A build-and-deploy run is a build, a push, and a reconcile poll. On the
  # native arm64 runner that fits inside an hour; an emulated fallback build
  # measured 40 minutes on a machine faster than a hosted runner, and the
  # reconcile happens AFTER it, so an hour is not a safe ceiling.
  #
  # This is only a CEILING. configure-aws-credentials requests 1 hour unless
  # told otherwise and does NOT refresh, so raising this alone would change
  # nothing — the workflow must also pass role-duration-seconds, and it does.
  # Keep the two in step: a request above this value fails the assume-role.
  # Tags come from the provider's default_tags (providers.tf).
  max_session_duration = 7200
}

data "aws_iam_policy_document" "gha_deploy_pipeline" {
  for_each = local.deploy_repos

  # GetAuthorizationToken has no resource-level permissions in ECR — the API
  # call is account-wide by definition, so `*` here is the only expressible
  # form. It yields a registry token whose actual reach is decided by the
  # statements below.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push to ONE repository. This is the shape github-oidc.tf's gha_ecr uses,
  # with the `${var.ecr_repository_prefix}/*` resource narrowed to this repo's
  # single service — that wildcard is the whole difference between "CI can ship
  # the api" and "CI can ship anything the box runs".
  #
  # This is exactly AWS's documented "push an image" action set
  # (docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html) and
  # nothing more. BatchGetImage is part of that set — the push path reads the
  # existing manifest back.
  #
  # Deliberately NOT granted: ecr:GetDownloadUrlForLayer, which is a PULL
  # permission — with BatchGetImage it would let this role read every layer
  # blob in the repository, which a build-and-push job never needs. Also not
  # granted: ecr:DescribeImages, which nothing in the workflow calls.
  # The cache is `type=gha`, not `type=registry`, so no pull grant is required
  # for layer reuse either.
  statement {
    sid = "EcrPushOwnRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
    ]
    resources = [local.deploy_ecr_repo_arns[each.key]]
  }

  # OPTIONAL (var.woodpecker_ecr_registry_cache, default off): read layers back
  # for a BuildKit type=registry cache. Needs a lifecycle rule for the cache tag
  # first (docs/woodpecker.md); the comment above about type=gha stays true while
  # this is off.
  dynamic "statement" {
    for_each = var.woodpecker_ecr_registry_cache ? [1] : []

    content {
      sid       = "EcrPullOwnRepositoryForRegistryCache"
      actions   = ["ecr:GetDownloadUrlForLayer"]
      resources = [local.deploy_ecr_repo_arns[each.key]]
    }
  }

  # Trigger the reconcile. Scoped by TAG rather than by instance ID, so an
  # instance replacement does not break every deploy role — see the note at the
  # top of this file. Both conditions are required: Stack keeps this inside one
  # environment (the objection to gha_deploy_ssm's Project-only condition), and
  # Name pins it to the app instance rather than anything else in that stack.
  statement {
    sid       = "SendCommandToStackAppInstance"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Stack"
      values   = [var.github_deploy_target_stack]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${var.github_deploy_target_stack}-app"]
    }
  }

  # Lets the workflow find the app instance by tag when `instance_id` is not
  # passed (see "Resolve target instance" in build-and-deploy.yml), so five caller
  # repos no longer carry a hard-coded instance ID that goes stale whenever
  # compute.tf replaces the box.
  #
  # `*` is forced: ec2:DescribeInstances supports NO resource-level permissions
  # (EC2 Service Authorization Reference), so this cannot be pinned to the app
  # instance. It is read-only metadata about instances in the account -- names,
  # tags, IPs -- and grants no ability to act on any of them; acting still needs
  # the tag-scoped SendCommand above. Accepted for the convenience of tag lookup;
  # the workflow also still honours an explicit `instance_id`.
  statement {
    sid       = "DescribeInstancesForTagLookup"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # SendCommand authorises the DOCUMENT as well as the target, so both ARNs are
  # needed for one call.
  #
  # BE HONEST ABOUT WHAT THIS ROLE CAN DO: AWS-RunShellScript's `commands`
  # parameter is an unconstrained string list executed as ROOT on the target,
  # and no IAM condition key can constrain its contents. So this role CAN run
  # arbitrary root commands on i-…, by design — that is what a deploy that
  # restarts containers is. Pinning the document does not remove that
  # primitive; it stops the role reaching OTHER documents, notably
  # AWS-RunRemoteScript, which would additionally fetch and execute a payload
  # from a URL. The containment that actually matters here is the single
  # instance ARN above, not the document pin.
  statement {
    sid     = "SendCommandDocument"
    actions = ["ssm:SendCommand"]
    # AWS-OWNED documents carry an EMPTY account component: the ARN is
    # arn:aws:ssm:<region>::document/AWS-RunShellScript, with two colons. AWS
    # manages these, so no account owns them. Naming this account here produces
    # an ARN that matches nothing, and every SendCommand is denied — the deploy
    # would fail at its last step, after the image was already in ECR.
    resources = ["arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"]
  }

  # Polling the command to completion. The workflow must FAIL when the
  # reconcile fails, and it cannot know that without reading the invocation
  # back.
  #
  # `*` is forced, and it is genuinely broader than it looks: ssm:
  # GetCommandInvocation supports NO resource types and NO condition keys
  # (SSM Service Authorization Reference — both cells are blank, and there is
  # no ssm:CommandId key to scope on). So this grant lets the role read the
  # stdout/stderr of ANY Run Command invocation in the account, including ones
  # an operator sent by hand, whose output may contain secrets. That is an
  # accepted risk of polling at all, not something the policy narrows — do not
  # read this statement as scoped.
  #
  # ListCommandInvocations is deliberately absent: the workflow polls by
  # CommandId and never lists.
  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy_pipeline" {
  for_each = local.deploy_repos
  name     = "${var.name_prefix}-gha-deploy-${each.value.service}"
  role     = aws_iam_role.gha_deploy_pipeline[each.key].id
  policy   = data.aws_iam_policy_document.gha_deploy_pipeline[each.key].json
}

output "gha_deploy_pipeline_role_arns" {
  description = "repo name => role ARN. Pass the matching one as the build-and-deploy workflow's `role_arn`. Empty unless manage_github_deploy_roles is on."
  value       = { for k, r in aws_iam_role.gha_deploy_pipeline : k => r.arn }
}
