# ecr.tf
# One repository per service, SHARED across environments so an image is built
# once and promoted dev -> staging -> prod by retagging, rather than rebuilt per
# environment (which would let dev and prod diverge silently).
#
# Because they are shared they are account-global: exactly ONE workspace (the
# `shared` one) sets manage_shared_ecr = true and owns them. Every other
# workspace reads them through a data source, so `shared` must be applied first.

resource "aws_ecr_repository" "svc" {
  for_each = var.manage_shared_ecr ? toset(keys(var.services)) : toset([])

  name = "${var.ecr_repository_prefix}/${each.key}"

  # MUTABLE so `latest` can be moved during bootstrap. Once deploys are driven
  # by commit-SHA tags (the recommended path), flip this to IMMUTABLE so a tag
  # can never be repointed under a running environment.
  image_tag_mutability = "MUTABLE"

  # NOT force_delete. FateRound sets force_delete = true, which is fine for a
  # single-app throwaway stack; here a `destroy` would take the images every
  # environment is running, including prod.
  force_delete = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.ecr_repository_prefix}-${each.key}" }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.ecr_keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Runtime environments look the shared repositories up rather than owning them.
data "aws_ecr_repository" "svc" {
  for_each = var.manage_shared_ecr ? toset([]) : toset(keys(local.enabled_services))
  name     = "${var.ecr_repository_prefix}/${each.key}"
}

locals {
  # service -> repository URL, from whichever side owns it in this workspace.
  ecr_repo_urls = var.manage_shared_ecr ? {
    for k, v in aws_ecr_repository.svc : k => v.repository_url
    } : {
    for k, v in data.aws_ecr_repository.svc : k => v.repository_url
  }

  # ARNs the instance role and the CI role are allowed to touch.
  ecr_repo_arns = var.manage_shared_ecr ? [
    for v in aws_ecr_repository.svc : v.arn
    ] : [
    for v in data.aws_ecr_repository.svc : v.arn
  ]
}
