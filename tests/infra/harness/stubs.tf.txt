# Test harness stubs for infra/github-oidc-deploy.tf (copied in by run-tests.sh).
# Declares only what that file reads from the rest of the stack. The aws
# provider is configured with fake credentials and every AWS-facing check off:
# the harness plans, it never applies, and nothing here talks to AWS.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

variable "name_prefix" {
  type    = string
  default = "storytime"
}

variable "ecr_repository_prefix" {
  type    = string
  default = "storytime"
}

variable "services" {
  type = map(any)
  default = {
    api          = {}
    web          = {}
    admin        = {}
    waitlist-api = {}
    waitlist-web = {}
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  github_oidc_provider_arn = "arn:aws:iam::772316781095:oidc-provider/token.actions.githubusercontent.com"
}

output "trust" {
  value = { for k, d in data.aws_iam_policy_document.gha_deploy_pipeline_assume : k => jsondecode(d.json) }
}

output "perms" {
  value = { for k, d in data.aws_iam_policy_document.gha_deploy_pipeline : k => jsondecode(d.json) }
}
