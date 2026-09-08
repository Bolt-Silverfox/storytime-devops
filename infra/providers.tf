provider "aws" {
  region = var.aws_region

  # Tag everything so the stack is identifiable, cost-attributable, and
  # cleanly separable from the hand-built legacy boxes it will replace.
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
