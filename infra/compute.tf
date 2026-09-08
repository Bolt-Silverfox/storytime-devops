# compute.tf
# ---------------------------------------------------------------------------
# TOPOLOGY DECISION: ONE INSTANCE PER ENVIRONMENT, SEVERAL CONTAINERS ON IT.
#
# FateRound runs one container on one box, so instance == app. Storytime is six
# services (backend API, web, superadmin, waitlist API, waitlist web, log viewer)
# across four environments. The two candidate shapes were:
#
#   (a) one instance per environment, several containers  <-- CHOSEN
#   (b) one instance per service per environment          (~20 instances)
#
# (a) because:
#   - It is what the boxes already do (one host serves many hostnames), so this
#     is a like-for-like codification rather than a re-architecture bundled into
#     the same change.
#   - (b) is ~20 EC2 instances and ~20 Elastic IPs for a platform whose total
#     traffic fits comfortably on two boxes. The cost is not justified by the
#     isolation gained, given there is still no ALB or ASG.
#   - Multiple hostnames must terminate somewhere; an on-box reverse proxy is
#     needed either way, and with (a) it is the only extra moving part.
#
# What (a) costs us, stated plainly:
#   - No per-service blast-radius isolation: one box down takes the environment
#     down. Same as today.
#   - Noisy-neighbour risk between containers. Mitigated by per-service memory
#     limits (var.services[*].memory_mb), which the current PM2 setup lacks.
#   - Redeploying one service via `terraform apply` replaces the whole instance
#     (user_data changes). Mitigated: the normal deploy path is CI calling
#     /usr/local/bin/redeploy.sh <service> <tag> over SSM Run Command, which
#     touches one container and never involves Terraform.
#
# If a single service later outgrows this, promote just that service to its own
# workspace rather than splitting everything.
#
# Replicas replace PM2 cluster mode: the prod API runs max(2, cpus-1) workers
# today, which becomes replicas = N containers on consecutive host ports, round
# robin behind the proxy.
# ---------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  count = var.create_instance ? 1 : 0

  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.app[0].id]
  iam_instance_profile   = aws_iam_instance_profile.app[0].name

  # The EIP only attaches after the instance exists, so it needs a launch-time
  # public IP or user_data has no egress (dnf/curl/ecr/ssm all fail).
  associate_public_ip_address = true

  # No key_name: there is no SSH key for this instance, by design.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # Hop limit 1 keeps IMDS unreachable from inside the containers, so a
    # compromised app process cannot mint instance-role credentials.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  # Plain templatefile: aws_instance.user_data takes raw text and Terraform does
  # the encoding. Do NOT base64encode here.
  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region        = var.aws_region
    prefix            = local.prefix
    environment       = var.environment
    enable_origin_tls = var.enable_origin_tls
    redis_mode        = var.redis_mode
    redis_image       = var.redis_container_image
    redis_policy      = var.redis_maxmemory_policy
    caddyfile         = local.caddyfile
    containers = [
      for c in local.containers : {
        service        = c.service
        container_name = c.container_name
        image          = "${local.ecr_repo_urls[c.service]}:${var.services[c.service].image_tag}"
        host_port      = c.host_port
        container_port = c.container_port
        memory_mb      = c.memory_mb
        extra_env      = c.extra_env
      }
    ]
  })

  # A user_data change alone updates in place WITHOUT re-running it, so the
  # instance must be replaced for bootstrap changes to take effect.
  user_data_replace_on_change = true

  tags = { Name = "${local.prefix}-app" }

  lifecycle {
    # data.aws_ami uses most_recent, so a new AL2023 publish would otherwise show
    # up as "must be replaced" on an unrelated apply. Pin to the launched AMI and
    # roll deliberately (taint / -replace) instead.
    ignore_changes = [ami]
  }
}

resource "aws_eip" "app" {
  count    = var.create_instance ? 1 : 0
  instance = aws_instance.app[0].id
  domain   = "vpc"

  tags = { Name = "${local.prefix}-eip" }
}
