# --- VPC ---
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "vpc-${var.name_prefix}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "igw-${var.name_prefix}" })
}

# --- Every VPC gets an unmanaged default security group automatically (open to itself,
# nothing else) the moment it's created — Terraform never provisioned it, so it isn't
# visible anywhere by default. Adopting it here and stripping every rule is the standard fix
# (Checkov CKV2_AWS_12): nothing should ever actually use this default SG (every real
# resource gets one of the purpose-built SGs in modules/aws/security), so an empty rule set
# costs nothing. Kept in this module rather than modules/aws/security so it sits next to
# aws_vpc.this directly — Checkov's cross-module graph analysis didn't reliably link the two
# when this lived in the security module and referenced the VPC only via var.vpc_id.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "sg-default-locked-${var.name_prefix}" })
}

# --- Public subnets — one per AZ, host the ALB and the NAT Gateway. ---
resource "aws_subnet" "public" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # Left off deliberately (Checkov CKV_AWS_130) — neither the ALB nor the NAT Gateway's EIP
  # depend on subnet-level auto-assign to get a public IP; both manage their own public
  # addressing explicitly (the NAT Gateway via aws_eip.nat below, the ALB via its own ENIs
  # once modules/aws/alb exists). Nothing in this module launches a bare EC2 instance that
  # would need this to reach the Internet, so turning it off costs nothing.
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "snet-public-${var.azs[count.index]}-${var.name_prefix}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rt-public-${var.name_prefix}" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT — single NAT Gateway (not one per AZ) is a deliberate dev-tier cost call, same
# reasoning as the Azure App Service B1/PostgreSQL Burstable choices: a single NAT is a
# shared point of failure across AZs, acceptable for dev, not for staging/prod (revisit
# there with one NAT Gateway per AZ once those environments exist). ---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "eip-nat-${var.name_prefix}" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.this]
  tags          = merge(var.tags, { Name = "nat-${var.name_prefix}" })
}

# --- ECS (private) subnets — outbound only, via the single NAT Gateway above. Fargate tasks
# for both ArkCloud.API and ArkCloud.Blazor live here; never directly reachable from the
# Internet, only through the ALB in the public subnets. ---
resource "aws_subnet" "ecs" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.ecs_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, { Name = "snet-ecs-${var.azs[count.index]}-${var.name_prefix}" })
}

resource "aws_route_table" "ecs" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rt-ecs-${var.name_prefix}" })
}

resource "aws_route" "ecs_nat" {
  route_table_id         = aws_route_table.ecs.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "ecs" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.ecs[count.index].id
  route_table_id = aws_route_table.ecs.id
}

# --- Database (private) subnets — no route to the Internet at all, not even via NAT. Same
# trust boundary as Azure's snet-database: only reachable from the ECS subnets (enforced by
# the security group in modules/aws/security, not by network routing alone). ---
resource "aws_subnet" "database" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, { Name = "snet-database-${var.azs[count.index]}-${var.name_prefix}" })
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rt-database-${var.name_prefix}" })
}

resource "aws_route_table_association" "database" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

resource "aws_db_subnet_group" "this" {
  name       = "dbsubnet-${var.name_prefix}"
  subnet_ids = aws_subnet.database[*].id
  tags       = merge(var.tags, { Name = "dbsubnet-${var.name_prefix}" })
}

# --- S3 gateway endpoint — free, no ENI/hourly cost like an interface endpoint. Lets ECS
# pull image layers staged via S3 (ECR's actual storage backend) and reach S3 in general
# without routing through the NAT Gateway — reduces NAT data-processing cost and doesn't
# depend on the NAT Gateway being healthy for image pulls specifically. Interface endpoints
# for ECR/Secrets Manager (which do cost per-hour/per-AZ) are left out for dev — the NAT
# Gateway already covers them adequately at this scale; revisit for staging/prod (Sprint 6+)
# if NAT data-processing cost or full network isolation (no NAT at all) becomes a real goal. ---
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.ecs.id, aws_route_table.public.id]

  tags = merge(var.tags, { Name = "vpce-s3-${var.name_prefix}" })
}

data "aws_region" "current" {}
