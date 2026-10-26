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
