# Plan-time assertions on the deploy roles' trust and permission documents.
# `terraform test` evaluates the policy documents (pure functions, no AWS calls).

variables {
  manage_github_deploy_roles = true
  github_deploy_target_stack = "storytime-prod"
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "772316781095" }
}

override_data {
  target = data.aws_region.current
  values = { name = "eu-west-1" }
}

run "defaults_change_nothing" {
  command = plan

  assert {
    condition     = alltrue([for k, t in output.trust : length(t.Statement) == 1])
    error_message = "With no Woodpecker inputs every trust policy must keep exactly its one OIDC statement."
  }
  assert {
    condition     = alltrue([for k, t in output.trust : t.Statement[0].Action == "sts:AssumeRoleWithWebIdentity"])
    error_message = "The remaining statement must be the Federated OIDC one."
  }
  assert {
    condition     = alltrue([for k, t in output.trust : jsonencode(t.Statement[0]) == jsonencode(output.expected_oidc[k])])
    error_message = "The OIDC statement (Effect, Action, Federated principal, aud, sub, job_workflow_ref) must equal the pinned expectation."
  }
  assert {
    condition     = alltrue([for k, r in aws_iam_role.gha_deploy_pipeline : issensitive(r.assume_role_policy)])
    error_message = "assume_role_policy must always be marked sensitive so a trust diff never prints an ExternalId."
  }
  assert {
    condition     = alltrue([for k, t in output.trust : !strcontains(jsonencode(t), "ExternalId")])
    error_message = "No ExternalId may appear while Woodpecker is unconfigured."
  }
  assert {
    condition     = alltrue([for k, p in output.perms : length(p.Statement) == 6])
    error_message = "Permission statements must be unchanged (6) with the cache flag off."
  }
}

run "arns_without_ids_fails_loudly" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime"]
  }
  expect_failures = [terraform_data.github_deploy_guards]
}

run "ids_without_arns_adds_nothing" {
  command = plan
  variables {
    woodpecker_external_ids = { api = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  }
  assert {
    condition     = alltrue([for k, t in output.trust : length(t.Statement) == 1])
    error_message = "ExternalIds alone (no agent role) must not open a trust statement."
  }
}

run "woodpecker_trust_added_per_service" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime"]
    woodpecker_external_ids = {
      api          = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      web          = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      admin        = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      waitlist-api = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      waitlist-web = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }
  }
  assert {
    condition     = alltrue([for k, t in output.trust : length(t.Statement) == 2])
    error_message = "Each role must gain exactly one extra statement."
  }
  assert {
    condition     = alltrue([for k, t in output.trust : t.Statement[0].Action == "sts:AssumeRoleWithWebIdentity"])
    error_message = "The OIDC statement must stay first and untouched."
  }
  assert {
    condition     = alltrue([for k, t in output.trust : jsonencode(t.Statement[0]) == jsonencode(output.expected_oidc[k])])
    error_message = "With Woodpecker set, the OIDC statement must still equal the pinned expectation exactly."
  }
  assert {
    condition     = alltrue([for k, r in aws_iam_role.gha_deploy_pipeline : issensitive(r.assume_role_policy)])
    error_message = "assume_role_policy carries the ExternalId and must be marked sensitive, or plans print it in plaintext."
  }
  assert {
    condition = alltrue([for k, t in output.trust :
    t.Statement[1].Action == "sts:AssumeRole" && t.Statement[1].Principal.AWS == "arn:aws:iam::772641335580:role/shared-spot-agent-storytime"])
    error_message = "The second statement must be sts:AssumeRole from the agent role only."
  }
  assert {
    condition = alltrue([for k, t in output.trust :
    contains(keys(t.Statement[1].Condition.StringEquals), "sts:ExternalId")])
    error_message = "The second statement must be conditioned on sts:ExternalId."
  }
  assert {
    condition     = output.trust["storytime_be"].Statement[1].Condition.StringEquals["sts:ExternalId"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "api's role must carry api's ExternalId."
  }
  assert {
    condition     = output.trust["storytime-fe"].Statement[1].Condition.StringEquals["sts:ExternalId"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    error_message = "web's role must carry web's ExternalId, not api's."
  }
}

run "cache_flag_adds_one_permission" {
  command = plan
  variables {
    woodpecker_ecr_registry_cache = true
  }
  assert {
    condition     = alltrue([for k, p in output.perms : length(p.Statement) == 7])
    error_message = "The cache flag must add exactly one permission statement."
  }
}

run "bad_external_id_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { api = "short" }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "agent_role_in_other_account_rejected" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::111122223333:role/some-role"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "duplicate_external_ids_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = {
      api   = "0123456789abcdef0123456789abcdef0123456789abcdef"
      admin = "0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "arn_other_role_in_ci_account_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/some-other-role"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_account_root_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:root"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_user_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:user/shared-spot-agent-storytime"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_role_wildcard_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/*"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_name_wildcard_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime*"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_path_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/x/shared-spot-agent-storytime"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_trailing_newline_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime\n"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_three_entries_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = [
      "arn:aws:iam::772641335580:role/shared-spot-agent-storytime",
      "arn:aws:iam::772641335580:role/shared-spot-agent-storytime-a",
      "arn:aws:iam::772641335580:role/shared-spot-agent-storytime-b",
    ]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_rotation_name_with_prefix_accepted" {
  command = plan
  variables {
    woodpecker_external_ids = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = [
      "arn:aws:iam::772641335580:role/shared-spot-agent-storytime",
      "arn:aws:iam::772641335580:role/shared-spot-agent-storytime-v2",
    ]
  }
}

run "external_id_31_chars_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { api = join("", [for i in range(31) : "a"]) }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "external_id_32_chars_accepted" {
  command = plan
  variables {
    woodpecker_external_ids = { api = join("", [for i in range(32) : "a"]) }
  }
}

run "external_id_128_chars_accepted" {
  command = plan
  variables {
    woodpecker_external_ids = { api = join("", [for i in range(128) : "a"]) }
  }
}

run "external_id_129_chars_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { api = join("", [for i in range(129) : "a"]) }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "external_id_underscore_accepted" {
  command = plan
  variables {
    woodpecker_external_ids = { api = "${join("", [for i in range(31) : "a"])}_" }
  }
}

run "external_id_space_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { api = "${join("", [for i in range(31) : "a"])} " }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "external_id_quote_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { api = "${join("", [for i in range(31) : "a"])}\"" }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "arn_role_name_over_64_chars_rejected" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime${join("", [for i in range(38) : "a"])}"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "arn_role_name_64_chars_accepted" {
  command = plan
  variables {
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime${join("", [for i in range(37) : "a"])}"]
  }
}

# ---- reviewable trust output (gha_deploy_trust_review) ----------------------
# The role's assume_role_policy is sensitive (it embeds the ExternalId), so a
# plan shows it as "(sensitive value)". gha_deploy_trust_review is the
# NON-sensitive twin: the same trust JSON with each ExternalId replaced by a
# truncated sha256, so a plan shows a real diff of principals, Sids, actions and
# OIDC aud/sub/job_workflow_ref.

run "review_equals_trust_by_default" {
  command = plan
  assert {
    condition     = jsonencode(output.gha_deploy_trust_review) == jsonencode(output.trust)
    error_message = "With no Woodpecker inputs the reviewable twin must equal the rendered trust document exactly."
  }
  assert {
    condition     = !issensitive(output.gha_deploy_trust_review)
    error_message = "The review output must be non-sensitive, otherwise plans cannot show the OIDC diff."
  }
}

run "review_shows_oidc_ref_change" {
  command = plan
  variables {
    github_deploy_repos = {
      "storytime_be" = { ref = "refs/heads/release", service = "api" }
    }
  }
  assert {
    condition     = output.gha_deploy_trust_review["storytime_be"].Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Bolt-Silverfox/storytime_be:ref:refs/heads/release"
    error_message = "A change of the deploy branch must be visible in the reviewable output."
  }
}

run "review_shows_workflow_sha_change" {
  command = plan
  variables {
    github_deploy_workflow_ref = [
      "Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@e8e832285ca78d3c49bd54142d9b5aa4fc1ad0b0",
      "Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@1111111111111111111111111111111111111111",
    ]
  }
  assert {
    condition = alltrue([for k, t in output.gha_deploy_trust_review :
    contains(t.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"], "Bolt-Silverfox/storytime-devops/.github/workflows/build-and-deploy.yml@1111111111111111111111111111111111111111")])
    error_message = "An added workflow SHA must be visible in every role's reviewable output."
  }
}

run "review_shows_repo_set_change" {
  command = plan
  variables {
    github_deploy_repos = {
      "storytime_be" = { ref = "refs/heads/main", service = "api" }
      "other-repo"   = { ref = "refs/heads/main", service = "web" }
    }
  }
  assert {
    condition     = jsonencode(sort(keys(output.gha_deploy_trust_review))) == jsonencode(["other-repo", "storytime_be"])
    error_message = "Adding or removing a deploy repo must change the reviewable output's keys."
  }
  assert {
    condition     = output.gha_deploy_trust_review["other-repo"].Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Bolt-Silverfox/other-repo:ref:refs/heads/main"
    error_message = "The new repo's sub claim must be visible."
  }
}

run "review_hashes_external_ids" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime"]
    woodpecker_external_ids = {
      api          = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      web          = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      admin        = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      waitlist-api = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      waitlist-web = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }
  }
  assert {
    condition     = alltrue([for k, t in output.gha_deploy_trust_review : length(t.Statement) == 2])
    error_message = "The review keeps both statements."
  }
  assert {
    condition = alltrue([for c in ["a", "b", "c", "d", "e"] :
    !strcontains(jsonencode(output.gha_deploy_trust_review), join("", [for i in range(64) : c]))])
    error_message = "No raw ExternalId may appear in the reviewable output."
  }
  assert {
    condition     = output.gha_deploy_trust_review["storytime_be"].Statement[1].Condition.StringEquals["sts:ExternalId"] == "sha256:${substr(sha256(join("", [for i in range(64) : "a"])), 0, 16)}"
    error_message = "api's review must carry the truncated sha256 of api's ExternalId, so a rotation shows as a diff."
  }
  assert {
    condition     = output.gha_deploy_trust_review["storytime-fe"].Statement[1].Condition.StringEquals["sts:ExternalId"] == "sha256:${substr(sha256(join("", [for i in range(64) : "b"])), 0, 16)}"
    error_message = "web's review must carry web's hash, not api's."
  }
  assert {
    condition = alltrue([for k, t in output.gha_deploy_trust_review :
    t.Statement[1].Sid == "WoodpeckerStorytimeLane" && t.Statement[1].Action == "sts:AssumeRole" && t.Statement[1].Principal.AWS == "arn:aws:iam::772641335580:role/shared-spot-agent-storytime"])
    error_message = "The review must show the Woodpecker Sid, action and principal."
  }
  assert {
    condition     = alltrue([for k, t in output.gha_deploy_trust_review : jsonencode(t.Statement[0]) == jsonencode(output.expected_oidc[k])])
    error_message = "The review's OIDC statement must equal the pinned expectation."
  }
}

# ---- mutation-proofing of the rendered Woodpecker statement ------------------

run "woodpecker_statement_sid_pinned" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime"]
    woodpecker_external_ids    = { for s in ["api", "admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" }
  }
  assert {
    condition     = alltrue([for k, t in output.trust : t.Statement[1].Sid == "WoodpeckerStorytimeLane" && t.Statement[1].Effect == "Allow"])
    error_message = "The Woodpecker statement must keep Sid WoodpeckerStorytimeLane and Effect Allow (the live roles carry this Sid)."
  }
}

# differs from the accepted ARN ONLY by the account id (same role name)
run "agent_role_other_account_same_name_rejected" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::111122223333:role/shared-spot-agent-storytime"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

# a 12-digit account that is not 772641335580 and differs in one digit only
run "agent_role_account_one_digit_off_rejected" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335581:role/shared-spot-agent-storytime"]
  }
  expect_failures = [var.woodpecker_agent_role_arns]
}

run "external_id_unknown_key_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = { bogus = "0123456789abcdef0123456789abcdef0123456789abcdef" }
  }
  expect_failures = [var.woodpecker_external_ids]
}

run "external_id_valid_key_with_extra_unknown_key_rejected" {
  command = plan
  variables {
    woodpecker_external_ids = {
      api   = "0123456789abcdef0123456789abcdef0123456789abcdef"
      admim = "fedcba9876543210fedcba9876543210fedcba9876543210"
    }
  }
  expect_failures = [var.woodpecker_external_ids]
}

# Documents (does not fix) the review hash's limits: an ExternalId that equals
# other policy text -- here the principal ARN -- makes the split/join replace that text
# everywhere in the review. Real IDs come from `openssl rand -hex 32` (docs).
# No network: the data sources are overridden at the top of this file.
run "review_weak_external_id_documented_behaviour" {
  command = plan
  variables {
    woodpecker_agent_role_arns = ["arn:aws:iam::772641335580:role/shared-spot-agent-storytime"]
    woodpecker_external_ids = merge(
      { for s in ["admin", "web", "waitlist-api", "waitlist-web"] : s => "${s}${join("", [for i in range(32) : "x"])}" },
      { api = "arn:aws:iam::772641335580:role/shared-spot-agent-storytime" }
    )
  }
  assert {
    condition     = !strcontains(jsonencode(output.gha_deploy_trust_review["storytime_be"]), "role/shared-spot-agent-storytime")
    error_message = "An ExternalId equal to the principal ARN replaces the principal in the review too (documented limit; never use such a value)."
  }
}
