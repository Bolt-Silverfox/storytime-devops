provider "aws" {
  region = var.aws_region

  # Wrong-account protection. This stack targets FateRound's AWS account
  # (772316781095), which ALSO hosts the FateRound application and a third-party
  # `Portfolio-Server`. An apply pointed at the wrong account by a stale
  # AWS_PROFILE would create a parallel copy of everything in someone else's
  # account, so the provider refuses to do anything if the caller's account is
  # not in this list. Set allowed_account_ids = [] to switch the check off.
  allowed_account_ids = var.allowed_account_ids

  # Tag everything so the stack is identifiable, cost-attributable, and cleanly
  # separable both from the hand-built legacy boxes it will replace AND from the
  # other workloads sharing this account. `Project = storytime` is what makes a
  # cost report or a "can I delete this?" question answerable; nothing here may
  # assume it is the only thing in the account.
  default_tags {
    tags = {
      Project     = var.name_prefix
      Environment = var.environment
      Stack       = local.prefix
      ManagedBy   = "terraform"
      Repo        = "Bolt-Silverfox/storytime-devops"
    }
  }
}
