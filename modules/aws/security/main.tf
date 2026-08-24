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
  # AWS reserves the "sg-" prefix for its own generated security group IDs — the `name`
  # argument can't start with it (tags.Name below is unrestricted, kept as sg-* for readability).
  name        = "alb-${var.name_prefix}"
  description = "Public entry point - HTTPS from the Internet, forwards to ECS target groups only."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP - redirected to HTTPS at the listener, not served directly"
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
  name        = "ecs-api-${var.name_prefix}"
  description = "ArkCloud.API Fargate tasks - the only ECS security group allowed into sg-database."
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
    description = "All outbound - RDS, Secrets Manager, ECR/GHCR, CloudWatch via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-ecs-api-${var.name_prefix}" })
}

resource "aws_security_group" "ecs_web" {
  name        = "ecs-web-${var.name_prefix}"
  description = "ArkCloud.Blazor Fargate tasks - deliberately absent from sg-database ingress list."
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
    description = "All outbound - image pulls, ArkCloud.API via ALB, CloudWatch via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-ecs-web-${var.name_prefix}" })
}

# Lives here rather than in modules/aws/secret-rotation, where it logically belongs, for a
# concrete reason: sg-database below uses inline `ingress` blocks, and the AWS provider treats
# inline rules as the complete authoritative set for a security group — any rule defined as a
# separate aws_vpc_security_group_ingress_rule elsewhere gets deleted on the next apply.
#
# That is not theoretical. The rotation Lambda's ingress rule was originally a separate resource
# in its own module, and it silently vanished twice: every apply removed it, the following
# refresh noticed and recreated it, and in between the Lambda had no path to RDS — which is what
# actually caused the "timeout expired" failure during rotation testing.
#
# Keeping the Lambda's SG here means its ingress can be inline too, so the two can't fight.
resource "aws_security_group" "secret_rotation" {
  name        = "secret-rotation-${var.name_prefix}"
  description = "Postgres password rotation Lambda - egress to RDS and AWS APIs, no ingress."
  vpc_id      = var.vpc_id

  # No ingress block at all — nothing ever connects TO a rotation Lambda.

  egress {
    description = "All outbound - RDS on the private subnets, Secrets Manager/RDS/ECS APIs via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-secret-rotation-${var.name_prefix}" })
}

resource "aws_security_group" "database" {
  name = "database-${var.name_prefix}"
  # Description deliberately left as-is even though the rotation Lambda is now also an allowed
  # source: security group descriptions are immutable in AWS, so editing this one forces
  # Terraform to destroy and recreate the security group — detaching it from a live RDS instance
  # in the process. Caught in a plan before applying; not worth a database outage to reword a
  # sentence. The ingress blocks below are the authoritative statement of who can connect.
  description = "RDS PostgreSQL - ingress from sg-ecs-api only. sg-ecs-web is never listed here on purpose."
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from ArkCloud API Fargate tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_api.id]
  }

  # The rotation Lambda's testSecret step connects for real to prove the new credential works
  # before promoting it (see modules/aws/secret-rotation/lambda/rotate.py) — so it needs to be
  # an allowed source. Inline here, deliberately: see the comment on sg-secret-rotation above.
  ingress {
    description     = "PostgreSQL from the password rotation Lambda (testSecret step)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.secret_rotation.id]
  }

  # No egress rule at all — RDS doesn't initiate outbound connections, nothing to allow.

  tags = merge(var.tags, { Name = "sg-database-${var.name_prefix}" })
}
