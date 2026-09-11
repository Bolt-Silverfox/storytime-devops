output "environment" {
  description = "Environment this workspace manages."
  value       = var.environment
}

output "instance_id" {
  description = "Instance ID. Use with `aws ssm start-session --target <id>` — there is no SSH."
  value       = try(aws_instance.app[0].id, null)
}

output "instance_public_ip" {
  description = <<-EOT
    The Elastic IP THIS STACK ACTUALLY HOLDS — the address the Namecheap A records
    point at.

    NULL when associate_eip = false, which is deliberate: the allocation is then
    either unattached or still held by the instance this stack is replacing, so
    reporting it here would be wrong exactly when a pre-cutover verification pass
    is relying on it. Use instance_direct_ip to reach the box in that state, and
    eip_allocation_id to see which address is waiting to be moved.
  EOT
  value       = local.service_address
}

output "instance_direct_ip" {
  description = "The instance's own auto-assigned public IPv4. This is how you verify a replacement stack BEFORE it takes the Elastic IP (associate_eip = false). Once the EIP is associated, AWS releases the auto-assigned address and this reports the Elastic IP instead."
  value       = local.instance_direct_ip
}

output "eip_address" {
  description = "The Elastic IP address this stack allocated or adopted, whether or not this stack currently holds it. Reported separately from instance_public_ip so a pre-cutover plan can show which address is about to move without claiming to serve it."
  value       = local.eip_address
}

output "eip_allocation_id" {
  description = <<-EOT
    Allocation id of the Elastic IP. THIS IS THE CUTOVER LEVER: a replacement
    stack sets eip_allocation_id to this value to take the live address over, and
    a rollback is putting it back. Keep it somewhere findable — it outlives every
    instance.
  EOT
  value       = local.eip_allocation_id
}

output "eip_remap_command" {
  description = "Emergency, out-of-band version of the cutover. Terraform is the normal path (see docs/migration.md step 7); this is for when you need the address moved right now and will reconcile state afterwards."
  value = (
    local.eip_allocation_id == null
    ? null
    : "aws ec2 associate-address --allocation-id ${local.eip_allocation_id} --instance-id <target-instance-id> --allow-reassociation --region ${var.aws_region}"
  )
}

output "dns_records_required" {
  description = <<-EOT
    The A records a human must create BY HAND at Namecheap (Domain List -> Manage
    -> Advanced DNS -> Host Records). Terraform does not manage DNS — see
    infra/dns.tf for why — so this output is the interface between the two.

    Once these exist, they never change again for a migration inside this AWS
    account: the Elastic IP moves instead.
  EOT
  value       = local.dns_records_required
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

output "database_endpoint" {
  description = "Where the app should reach Postgres: the RDS endpoint when use_managed_database = true, otherwise the container's name on the box's docker network."
  value       = var.use_managed_database ? try(aws_db_instance.main[0].endpoint, null) : "postgres:5432 (container, loopback-published on 127.0.0.1:5432)"
}

output "database_backend" {
  description = "Which database backend this stack uses."
  value       = var.use_managed_database ? "rds" : "container"
}

output "backup_bucket" {
  description = "S3 bucket holding the nightly pg_dump output."
  value       = try(aws_s3_bucket.backups[0].bucket, null)
}

output "backup_health_check" {
  description = "Run this to see when the last backup actually succeeded. A stale timestamp is how a backup failure surfaces without shell access to the box."
  value = try(
    "aws s3 cp s3://${aws_s3_bucket.backups[0].bucket}/_status/last-success.json - | cat",
    null
  )
}

output "restore_verification_check" {
  description = <<-EOT
    Run this to see when a dump was last actually restored and its tables counted.
    A STALE timestamp means the backups are unproven.

    Null means verification is not installed (enable_restore_verification = false)
    — which is a different thing from "installed but failing", and the two must not
    look alike. Without the gate this printed a command that 404s, making a
    deliberately disabled job indistinguishable from a broken one.
  EOT
  value = (
    var.enable_restore_verification
    ? try("aws s3 cp s3://${aws_s3_bucket.backups[0].bucket}/_status/last-restore-verify.json - | cat", null)
    : null
  )
}

output "memory_budget" {
  description = "Committed container memory vs the instance's RAM. Enforced at plan time by guards.tf."
  value = {
    instance_type   = var.instance_type
    instance_ram_mb = local.instance_ram_known ? local.instance_ram_total_mb : null
    app_mb          = local.app_memory_mb
    postgres_mb     = local.postgres_container_mb
    redis_mb        = local.redis_container_mb
    host_reserve_mb = var.host_reserved_mb
    committed_mb    = local.committed_memory_mb
    headroom_mb     = local.instance_ram_known ? local.instance_ram_total_mb - local.committed_memory_mb : null
  }
}

output "shared_db_endpoint" {
  description = "Endpoint of the EXISTING legacy shared RDS instance, looked up read-only. It currently serves dev, staging, blue AND prod at once; this is the migration SOURCE, not a target."
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
