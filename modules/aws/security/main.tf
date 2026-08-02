# ---------------------------------------------------------------------------
# AWS security groups are allow-list only — unlike Azure NSGs (modules/azure/network),
# there is no explicit "Deny" rule to write. The Azure nsg-web has a literal
# DenyOutboundToDatabase rule making "Blazor never talks to PostgreSQL" a visible fact in
# the ruleset itself. The AWS equivalent of that same guarantee is structural instead of
# explicit: sg-database's ingress rule only names sg-ecs-api as an allowed source — sg-ecs-web
# is simply never mentioned anywhere in it. Default-deny does the rest; there's no rule to
# read that says "and Blazor is blocked" because in this model absence of a rule *is* the
# block. Worth knowing so nobody goes looking for a Deny rule that doesn't exist on this side.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "sg-alb-${var.name_prefix}"
  description = "Public entry point — HTTPS from the Internet, forwards to ECS target groups only."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP — redirected to HTTPS at the listener, not served directly"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To ECS tasks only, not the open Internet"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["10.0.11.0/24", "10.0.12.0/24"]
  }

  tags = merge(var.tags, { Name = "sg-alb-${var.name_prefix}" })
}

resource "aws_security_group" "ecs_api" {
  name        = "sg-ecs-api-${var.name_prefix}"
  description = "ArkCloud.API Fargate tasks — the only ECS security group allowed into sg-database."
  vpc_id      = var.vpc_id

  ingress {
    description     = "From the ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Outbound left open: needs to reach RDS (5432), Secrets Manager, ECR/GHCR for image pulls,
  # and CloudWatch — all over HTTPS/postgres via the NAT Gateway. Same posture as Azure's
  # snet-api (VNet integration is outbound-only, nothing restricts egress there either).
  egress {
    description = "All outbound — RDS, Secrets Manager, ECR/GHCR, CloudWatch via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-ecs-api-${var.name_prefix}" })
}

resource "aws_security_group" "ecs_web" {
  name        = "sg-ecs-web-${var.name_prefix}"
  description = "ArkCloud.Blazor Fargate tasks — deliberately absent from sg-database's ingress list."
  vpc_id      = var.vpc_id

  ingress {
    description     = "From the ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Same as sg-ecs-api: open egress for image pulls / calling ArkCloud.API's ALB endpoint /
  # CloudWatch. The isolation from PostgreSQL comes from sg-database never listing this SG as
  # a source, not from restricting egress here — see the module-level comment above.
  egress {
    description = "All outbound — image pulls, ArkCloud.API via ALB, CloudWatch via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-ecs-web-${var.name_prefix}" })
}

resource "aws_security_group" "database" {
  name        = "sg-database-${var.name_prefix}"
  description = "RDS PostgreSQL — ingress from sg-ecs-api only. sg-ecs-web is never listed here on purpose."
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from ArkCloud.API's Fargate tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_api.id]
  }

  # No egress rule at all — RDS doesn't initiate outbound connections, nothing to allow.

  tags = merge(var.tags, { Name = "sg-database-${var.name_prefix}" })
}

# --- Every VPC gets an unmanaged default security group automatically (open to itself,
# nothing else) the moment it's created — Terraform never provisioned it, so it isn't
# visible anywhere above. Adopting it here and stripping every rule is the standard fix
# (Checkov CKV2_AWS_12): nothing should ever actually use this default SG (every real
# resource gets one of the purpose-built SGs above), so an empty rule set costs nothing. ---
resource "aws_default_security_group" "this" {
  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = "sg-default-locked-${var.name_prefix}" })
}
