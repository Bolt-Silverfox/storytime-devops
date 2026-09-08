# network.tf
# One VPC per environment. Public subnet for the app host, plus private subnets
# for data services (RDS / ElastiCache) so nothing with a database in it is
# reachable from the internet.
#
# No NAT gateway (~$32/mo) and no ALB (~$16/mo): the app host sits in the public
# subnet with an Elastic IP and reaches ECR/SSM straight out through the IGW.
# Private subnets have NO egress route, which is fine — RDS and ElastiCache do
# not need outbound internet.
#
# NOTE: the existing shared RDS (emerj-shared-db) is PUBLICLY resolvable, so
# while environments still point at it they reach it over the internet rather
# than inside this VPC. That is a finding, not a design: see README.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  count = var.create_instance ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  count  = var.create_instance ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = { Name = "${local.prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = var.create_instance ? 1 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]

  # The instance gets a launch-time public IP (user-data needs egress before the
  # EIP attaches); the EIP then provides the stable address.
  map_public_ip_on_launch = false

  tags = { Name = "${local.prefix}-public" }
}

# Two private subnets in different AZs: RDS and ElastiCache subnet groups both
# require at least two AZs even for a single-AZ deployment.
resource "aws_subnet" "private" {
  count = var.create_instance ? 2 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${local.prefix}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  count  = var.create_instance ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = { Name = "${local.prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = var.create_instance ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

# Private route table with no default route: local VPC traffic only.
resource "aws_route_table" "private" {
  count  = var.create_instance ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = { Name = "${local.prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = var.create_instance ? 2 : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}
