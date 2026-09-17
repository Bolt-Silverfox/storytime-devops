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
# THE INSTANCE ID IS A CROSS-WORKSPACE COUPLING — READ THIS BEFORE AN APPLY.
# The roles live in `shared`; the EC2 instance they may SendCommand to lives in
# `prod`. There is no state link between the two, so the ID is passed in by
# hand via `github_deploy_instance_id`. If the prod instance is ever REPLACED
# (compute.tf replaces it on a user-data or AMI change), its ID changes and
# every deploy then fails with AccessDenied on ssm:SendCommand until this
# variable is updated and `shared` is re-applied. That is deliberate: an
# explicit ID is what makes "this role can only talk to that one box" true. If
# instance churn ever makes it painful, the alternative is the tag condition
# gha_deploy_ssm already uses (ssm:resourceTag/Project) — which is weaker,
# because it re-widens the grant to every instance in the project including
# whichever environment you did not mean to deploy.
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

variable "github_deploy_instance_id" {
  description = <<-EOT
    The ONE EC2 instance the deploy roles may target with ssm:SendCommand,
    e.g. "i-07cce36e829161c03". Required when manage_github_deploy_roles is on.

    This is the prod instance ID, and `shared` has no state link to the `prod`
    workspace that creates it — see the header note. Re-apply `shared` whenever
    the instance is replaced, or deploys start failing with AccessDenied.
  EOT
  type        = string
  default     = ""

  validation {
    # A blank or malformed ID would produce an ARN like `.../instance/` — which
    # IAM accepts as a literal and then matches nothing, so every deploy would
    # fail with an AccessDenied that looks like a policy bug rather than a typo.
    condition     = var.github_deploy_instance_id == "" || can(regex("^i-[0-9a-f]{8,32}$", var.github_deploy_instance_id))
    error_message = "github_deploy_instance_id must look like i-0123456789abcdef0."
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

    (It is NOT, as an earlier draft of this comment claimed, a fork-PR hole: a
    `pull_request` run from a fork has its token permissions downgraded to
    read-only, and `id-token` has no read level, so such a run cannot mint an
    OIDC token at all. The wildcard is dangerous for the same-repo reason
    above, not that one.)

    The subject is the CALLING repo's, not this one's: build-and-deploy.yml is
    a reusable workflow and GitHub mints the OIDC token against the caller.

    SUBJECT FORMAT HAS A MIGRATION TRAP. These values use the classic
    `repo:OWNER/REPO:ref:...` form, which is what both current repos emit.
    GitHub's immutable format (`repo:OWNER@ID/REPO@ID:ref:...`) applies to
    repos created after 2026-07-15 AND to any repo RENAMED or TRANSFERRED after
    that date. A rename of storytime_be, or a move between orgs, therefore
    silently stops matching this trust policy and every deploy fails with a
    bare STS AccessDenied. Check with:
      gh api repos/<owner>/<repo>/actions/oidc/customization/sub

    Deliberately starts with storytime_be ONLY. The chain gets proven end to
    end for one service before the other four are added — a broken deploy role
    that lands for five repos at once is five outages, not one.
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
    "storytime_be" = { ref = "refs/heads/main", service = "api" }
  }
}

variable "github_deploy_workflow_ref" {
  description = <<-EOT
    The exact reusable workflow permitted to assume a deploy role, as the OIDC
    `job_workflow_ref` claim spells it. Callers must reference this same ref
    (`...@main`) or the assume-role fails.
  EOT
  type        = string
  default     = "Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@refs/heads/main"
}

locals {
  deploy_repos = var.manage_github_deploy_roles ? var.github_deploy_repos : {}

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
      condition     = var.github_deploy_instance_id != ""
      error_message = "github_deploy_instance_id must be set when manage_github_deploy_roles is true; otherwise the SSM grant matches no instance and every deploy fails with AccessDenied."
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
      identifiers = [data.aws_iam_openid_connect_provider.github_existing[0].arn]
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
      values   = [var.github_deploy_workflow_ref]
    }
  }
}

resource "aws_iam_role" "gha_deploy_pipeline" {
  for_each           = local.deploy_repos
  name               = "${var.name_prefix}-gha-deploy-${each.value.service}"
  description        = "Builds ${each.key} and pushes ${var.ecr_repository_prefix}/${each.value.service}, then reconciles ${var.github_deploy_instance_id}."
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_pipeline_assume[each.key].json

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

  # Trigger the reconcile. Pinned to ONE instance, not the project tag: a tag
  # condition would let the api repo's pipeline redeploy every environment's
  # box, which is the scope mistake gha_deploy_ssm makes.
  statement {
    sid       = "SendCommandToOneInstance"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${var.github_deploy_instance_id}"]
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
    sid       = "SendCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:document/AWS-RunShellScript"]
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
