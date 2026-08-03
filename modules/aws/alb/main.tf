# Azure gives ArkCloud.API and ArkCloud.Blazor two separate hostnames for free
# (app-arkcloud-api-dev.azurewebsites.net / app-arkcloud-web-dev.azurewebsites.net) because
# each is its own App Service. An ALB doesn't have an equivalent without either a second ALB
# or a real custom domain with host-based routing rules — neither justified yet at this stage.
# Path-based routing on a single ALB is the pragmatic dev-tier choice instead: /api/* forwards
# to the API target group, everything else (default action) forwards to the web target group.
# ArkCloud.Blazor's AWS-side Api__BaseUrl setting (wired in modules/aws/ecs) needs to point at
# "<alb-dns-name>/api" to match, unlike its Azure counterpart which points at a separate host.
#
# HTTPS is deliberately NOT set up here — an ACM certificate needs a real domain (Route 53 or
# externally-owned) to validate against, which doesn't exist for this project yet. The listener
# below is plain HTTP on port 80. sg-alb already has port 443 open in anticipation of this
# (see modules/aws/security's comment), so adding an HTTPS listener + ACM cert later is a
# pure addition, not a rework — tracked as Sprint 6 hardening alongside the other TLS/private
# endpoint items already deferred there.

resource "aws_lb" "this" {
  name               = "alb-${var.name_prefix}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids

  # Dev-tier: allow `terraform destroy` to remove the ALB without a manual protection toggle
  # first, same call as RDS's deletion_protection and the ECR repos' force_delete.
  enable_deletion_protection = false

  # Free hardening, no reason not to enable it: rejects malformed/ambiguous headers instead of
  # forwarding them to the targets.
  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = "alb-${var.name_prefix}" })
}

resource "aws_lb_target_group" "api" {
  name        = "tg-api-${var.name_prefix}"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate awsvpc networking registers ENIs, not instance IDs

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "tg-api-${var.name_prefix}" })
}

resource "aws_lb_target_group" "web" {
  name        = "tg-web-${var.name_prefix}"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "tg-web-${var.name_prefix}" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Default action = web, matching Blazor being the "root" experience on Azure too
  # (app-arkcloud-web-dev is the one browsers hit directly).
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
