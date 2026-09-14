# ---------------------------------------------------------------------------
# Write-only CI role for seeding SSM from each repo's ENV_FILE secret.
#
# WHY THIS EXISTS
# The five app repos each hold one opaque GitHub Actions secret, ENV_FILE, that
# is the whole of that host's .env. Those secrets survived the destruction of
# the EC2 hosts and are NEWER than any .env left on a laptop, which makes them
# the authoritative recovery artifact. The GitHub API never returns a secret's
# value, so the only way to get them into SSM is to let a workflow — not a
# person — read them and write them straight across.
#
# WHY IT IS NOT THE gha_deploy ROLE
# gha_deploy lives in github-oidc.tf behind `manage_github_oidc`, which MUST
# STAY FALSE for account 772316781095: the FateRound stack already created an
# OIDC provider for token.actions.githubusercontent.com there, AWS allows
# exactly one per URL per account, and a second one fails the apply. This file
# takes the workaround that github-oidc.tf documents — it looks the existing
# provider up as a DATA source and reuses its ARN — so it can be enabled on its
# own without flipping that flag.
#
# WHY IT CANNOT READ
# The policy grants ssm:PutParameter and nothing else. No GetParameter, no
# GetParametersByPath, no DescribeParameters. A role that can seed a secret but
# can never read one back cannot be turned into an exfiltration path, by a
# compromised workflow or by whoever holds the AWS console. The instances read
# their own subtree with a different role (iam.tf, SsmReadOwnEnvironment).
#
# Account-global, like ECR: apply it in the `shared` workspace only.
# ---------------------------------------------------------------------------

variable "manage_github_ssm_seed_role" {
  description = <<-EOT
    Create the write-only CI role used to seed SSM from the app repos' ENV_FILE
    secrets. Account-global — set this true in the `shared` workspace ONLY, or
    four workspaces will fight over one role name.

    Unlike `manage_github_oidc`, this is safe to turn on in account
    772316781095: it consumes the existing OIDC provider rather than creating a
    second one.
  EOT
  type        = bool
  default     = false
}

variable "github_ssm_seed_repos" {
  description = <<-EOT
    One entry per app repo: the branch its caller workflow lives on, and the
    single `service` path segment that repo is allowed to write.

    ONE ROLE PER REPO, not one shared role. A single role scoped to
    `parameter/storytime-*` would let the waitlist front-end's dev branch
    overwrite /storytime-prod/api/DATABASE_URL. That is not a read path — the
    role still cannot decrypt anything — but repointing a production database
    URL or API base at attacker infrastructure is exfiltration with extra steps,
    and four of these five repos are public.

    `ref` is enumerated, never wildcarded: `repo:Bolt-Silverfox/*` would let a
    pull_request from a stranger's fork assume a role that writes production
    configuration.

    The subject is the CALLING repo's, not this one's: the seeding workflow is a
    reusable workflow, and GitHub mints the token against the caller.
  EOT
  type = map(object({
    ref     = string
    service = string
  }))

  # The role name is derived from `service`, but the map is keyed by repo. Two
  # repos sharing a service would produce two roles with one name, and that
  # surfaces as an EntityAlreadyExists part-way through an apply rather than at
  # plan time. Catch it here instead.
  validation {
    condition     = length(distinct([for r in var.github_ssm_seed_repos : r.service])) == length(var.github_ssm_seed_repos)
    error_message = "Each repo must map to a distinct `service`; the role name is derived from it."
  }

  default = {
    "storytime_be"          = { ref = "refs/heads/develop-v1.3.0", service = "api" }
    "storytime-fe"          = { ref = "refs/heads/dev", service = "web" }
    "storytime_superadmin"  = { ref = "refs/heads/dev", service = "admin" }
    "storytime-waitlist-be" = { ref = "refs/heads/main", service = "waitlist-api" }
    "storytime-waitlist-fe" = { ref = "refs/heads/dev", service = "waitlist-web" }
  }
}

variable "github_ssm_seed_workflow_ref" {
  description = <<-EOT
    The exact reusable workflow permitted to assume the seed role, as the OIDC
    `job_workflow_ref` claim spells it. Callers must reference this same ref
    (`...@main`) or the assume-role fails.
  EOT
  type        = string
  default     = "Bolt-Silverfox/storytime-devops/.github/workflows/seed-ssm-from-envfile.yml@refs/heads/main"
}

# The provider this stack does NOT manage. Data source, not a resource: if it is
# missing the plan fails loudly rather than silently creating a duplicate.
data "aws_iam_openid_connect_provider" "github_existing" {
  count = var.manage_github_ssm_seed_role ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  ssm_seed_repos = var.manage_github_ssm_seed_role ? var.github_ssm_seed_repos : {}

  # Must stay in step with the `case` in the seed workflow's Validate step.
  # Enumerated so the policy's `*` cannot span a `/`; see the policy comment.
  ssm_seed_environments = ["dev", "staging", "blue", "prod", "all", "shared"]
}

data "aws_iam_policy_document" "gha_ssm_seed_assume" {
  for_each = local.ssm_seed_repos

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
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

    # `sub` alone would authorise ANY workflow running on that branch — and four
    # of the five repos are public, so that is "anyone who can land a commit on
    # dev", plus every third-party action already in those workflows.
    # job_workflow_ref is the claim that makes "only the seed workflow" true
    # rather than aspirational: it identifies the REUSABLE workflow being run,
    # regardless of which caller invoked it.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = [var.github_ssm_seed_workflow_ref]
    }
  }
}

resource "aws_iam_role" "gha_ssm_seed" {
  for_each           = local.ssm_seed_repos
  name               = "${var.name_prefix}-gha-ssm-seed-${each.value.service}"
  description        = "Write-only: seeds /*/${each.value.service}/* from ${each.key}'s ENV_FILE. Cannot read them back."
  assume_role_policy = data.aws_iam_policy_document.gha_ssm_seed_assume[each.key].json

  # A seeding run is a handful of PutParameter calls. Anything longer is a
  # workflow that has gone wrong or a token that has been lifted.
  # Tags come from the provider's default_tags (providers.tf).
  max_session_duration = 3600
}

data "aws_iam_policy_document" "gha_ssm_seed" {
  for_each = local.ssm_seed_repos

  # Write only, only under this project's own prefixes, and only in this repo's
  # own service subtree.
  #
  # The environment segment is ENUMERATED, not wildcarded. An IAM resource `*`
  # matches `/` — it has no path-segment semantics — so a single
  # `parameter/${name_prefix}-*/<service>/*` would also match
  # /storytime-prod/api/<service>/DATABASE_URL, with `-*` absorbing "prod/api".
  # That name sits INSIDE the api subtree, and user-data.sh.tftpl reads it with
  # get-parameters-by-path --recursive and derives the env key from the last
  # segment, so the waitlist repo's dev branch could still repoint prod's
  # DATABASE_URL. Enumerating the environment leaves `*` spanning only the key.
  statement {
    sid     = "SsmWriteOwnServicePrefixes"
    actions = ["ssm:PutParameter"]
    resources = [
      for e in local.ssm_seed_environments :
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}-${e}/${each.value.service}/*"
    ]
  }

  # Belt and braces for the same class of escape as the enumeration above.
  # IAM authorises the ARN as written; if SSM were ever to normalise a name,
  # /storytime-prod/waitlist-web/../api/DATABASE_URL would pass the Allow and
  # then land in the api subtree. Nothing legitimate contains "..", and the
  # workflow's KEY regex cannot produce one, so denying it costs nothing.
  statement {
    sid       = "DenyDotDotInParameterName"
    effect    = "Deny"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/*..*"]
  }

  # SecureString on the AWS-managed aws/ssm key. Encrypt only — no Decrypt, so
  # the grant cannot be walked back into a read.
  #
  # Pinned to that one key rather than "*": this account also hosts FateRound
  # and a third-party Portfolio-Server, and a ViaService condition alone would
  # still let the role encrypt under THEIR keys. That leaks nothing, but it
  # would let a wrong-key parameter be written that the EC2 read role cannot
  # decrypt — a self-inflicted outage that looks like a bug in the app.
  statement {
    sid       = "KmsEncryptViaSsm"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.ssm[0].target_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

data "aws_kms_alias" "ssm" {
  count = var.manage_github_ssm_seed_role ? 1 : 0
  name  = "alias/aws/ssm"
}

resource "aws_iam_role_policy" "gha_ssm_seed" {
  for_each = local.ssm_seed_repos
  name     = "${var.name_prefix}-gha-ssm-seed-${each.value.service}"
  role     = aws_iam_role.gha_ssm_seed[each.key].id
  policy   = data.aws_iam_policy_document.gha_ssm_seed[each.key].json
}

output "gha_ssm_seed_role_arns" {
  description = "repo name => role ARN. Pass the matching one as the seed workflow's `role_arn`. Empty unless manage_github_ssm_seed_role is on."
  value       = { for k, r in aws_iam_role.gha_ssm_seed : k => r.arn }
}
