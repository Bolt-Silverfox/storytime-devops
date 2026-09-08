output "environment" {
  description = "Environment this workspace manages."
  value       = var.environment
}

output "instance_id" {
  description = "Instance ID. Use with `aws ssm start-session --target <id>` — there is no SSH."
  value       = try(aws_instance.app[0].id, null)
}

output "instance_public_ip" {
  description = "Elastic IP. Point DNS here."
  value       = try(aws_eip.app[0].public_ip, null)
}

output "ecr_repository_urls" {
  description = "service -> ECR repository URL. Push images here; the tag must match services[<name>].image_tag."
  value       = local.ecr_repo_urls
}

output "hostnames" {
  description = "Every public hostname this environment serves."
  value       = local.all_hostnames
}

output "ssm_config_path" {
  description = "Root of this environment's config in SSM Parameter Store."
  value       = "/${local.prefix}/"
}

output "redis_endpoint" {
  description = "Redis connection string for this environment. Place it into the apps' own config keys yourself — it is not auto-injected, because the variable name differs per app."
  value       = local.redis_endpoint
}

output "dedicated_db_endpoint" {
  description = "Endpoint of this environment's dedicated RDS instance, when create_database = true."
  value       = try(aws_db_instance.main[0].endpoint, null)
}

output "shared_db_endpoint" {
  description = "Endpoint of the EXISTING shared RDS instance, looked up read-only. Note it currently serves dev, staging, blue AND prod at once."
  value       = try(data.aws_db_instance.shared[0].endpoint, null)
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repo variable in each app repo's build workflow. Only produced by the `shared` workspace."
  value       = try(aws_iam_role.gha_deploy[0].arn, null)
}

output "caddyfile" {
  description = "The rendered reverse-proxy configuration, so the routing is reviewable without logging into the box."
  value       = local.caddyfile
}
