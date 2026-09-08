# security.tf
# Security groups. web_ingress_ipv4 / web_ingress_ipv6 are defined in cloudflare.tf.

resource "aws_security_group" "app" {
  count = var.create_instance ? 1 : 0

  name_prefix = "${local.prefix}-app-"
  description = "Storytime app host: web ingress, all egress. No SSH (SSM Session Manager instead)."
  vpc_id      = aws_vpc.main[0].id

  # DELIBERATELY NO PORT 22 RULE.
  # Shell access is via SSM Session Manager, which needs no inbound port and no
  # key material. If you find yourself wanting to add 22 here, add the reason to
  # the README first.

  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = local.web_ingress_ipv4
    ipv6_cidr_blocks = local.web_ingress_ipv6
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = local.web_ingress_ipv4
    ipv6_cidr_blocks = local.web_ingress_ipv6
  }

  egress {
    description = "All outbound (ECR, SSM, RDS, third-party APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# Data-tier SG: reachable only from the app host's SG, never from the internet.
resource "aws_security_group" "data" {
  count = var.create_instance ? 1 : 0

  name_prefix = "${local.prefix}-data-"
  description = "Storytime data tier (RDS / ElastiCache): reachable only from the app security group."
  vpc_id      = aws_vpc.main[0].id

  ingress {
    description     = "Postgres from the app host"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app[0].id]
  }

  ingress {
    description     = "Redis from the app host"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app[0].id]
  }

  tags = { Name = "${local.prefix}-data-sg" }

  lifecycle {
    create_before_destroy = true
  }
}
