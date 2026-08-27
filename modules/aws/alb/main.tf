# Azure gives ArkCloud.API and ArkCloud.Blazor two separate hostnames for free
# (app-arkcloud-api-dev.azurewebsites.net / app-arkcloud-web-dev.azurewebsites.net) because
# each is its own App Service. An ALB doesn't have an equivalent without either a second ALB
# or a real custom domain with host-based routing rules — neither justified yet at this stage.
# Path-based routing on a single ALB is the pragmatic dev-tier choice instead: /api/* forwards
# to the API target group, everything else (default action) forwards to the web target group.
# ArkCloud.Blazor's AWS-side Api__BaseUrl setting (wired in modules/aws/ecs) needs to point at
# "<alb-dns-name>/api" to match, unlike its Azure counterpart which points at a separate host.
#
# HTTPS (Sprint 6): still no real domain for this project (Route 53 or externally-owned), so a
# publicly-trusted ACM certificate — which requires DNS or email validation against a domain you
# own — isn't obtainable yet. Rather than leave the ALB on plain HTTP indefinitely, this uses a
# self-signed certificate (tls_private_key + tls_self_signed_cert below) imported into ACM
# (aws_acm_certificate with private_key/certificate_body, the "import" flow — no domain
# validation involved, since you're bringing an already-signed cert). This gets real TLS
# encryption in transit on the browser-to-ALB hop; what it does NOT get is a trusted chain —
# browsers will show a certificate warning, since nothing vouches for this cert's CN. Acceptable
# for dev (only used by health checks and direct testing, no real end users). Swap to a real ACM
# DNS-validated certificate the moment a domain exists for this project — the listener/cert
# resources below don't need to change shape, just point `aws_lb_listener.https` at a real
# `aws_acm_certificate` instead of this module's self-signed one.
data "aws_caller_identity" "current" {}

# STRIDE Sprint 6 remediation ("Repudiation" gap, flow 1: navigateur → ALB) — until now nothing
# proved after the fact who actually reached the ALB: the application logs its own requests,
# but not the load-balancer layer in front of it. Checkov CKV_AWS_91 already flagged this at
# Sprint 6 and was skipped for lack of a dedicated bucket (see ArkCloudInfra README §9) — this
# closes both the STRIDE gap and that skip at the same time.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "arkcloud-alb-logs-${var.name_prefix}-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, { Name = "s3-alb-logs-${var.name_prefix}" })
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 (AES256) isn't the usual "a managed key is enough for dev" shortcut used elsewhere in
# this project — it's the ONLY server-side encryption option ELB access logging supports. A
# KMS-encrypted bucket here would silently fail delivery (confirmed in AWS's own access-logging
# documentation), so this isn't a choice to revisit later like the RDS/Secrets Manager ones.
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Same protective reasoning as modules/aws/cloudtrail's bucket: these logs are the evidence
# this whole change exists to produce, so guarding them against accidental/malicious
# overwrite-or-delete is worth the near-zero cost even at dev-tier.
resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Same 90-day dev-tier retention window already used for CloudTrail (modules/aws/cloudtrail)
# and the Azure NSG flow logs (modules/azure/flow-logs) — one consistent log-retention story
# across the project instead of a bespoke value per bucket.
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# AWS's current (post-August 2022) recommended policy: a single service principal valid in
# every region, replacing the old per-region "ELB account ID" lookup table. eu-west-1 predates
# August 2022, but AWS's own documentation confirms the new policy is accepted there too — the
# legacy per-region-account-ID form is kept only for backward compatibility, not required for
# new setups.
#
# Deliberately NO aws:SourceArn condition here (first version of this file had one, via ArnLike)
# — real apply failed twice with "Access Denied for bucket" even after the policy had clearly
# propagated (retried well after the first attempt). Root cause: IAM evaluates a condition that
# references a context key the request doesn't actually populate as FALSE, not "ignored" — if
# the ELB log-delivery service doesn't reliably set aws:SourceArn on this PutObject call, adding
# that condition silently turns the whole Allow into a no-op. Neither AWS's own baseline policy
# example nor a verified working Terraform config from a third party use this condition; the
# resource path below (scoped to this account's AWSLogs prefix) is what actually restricts
# access, matching both references exactly instead of adding an untested condition.
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name  = "alb-${var.name_prefix}.arkcloud.internal"
    organization = "ArkCloud"
  }

  validity_period_hours = 8760 # 1 year — dev cert, expected to be replaced by a real one before then
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  tags = merge(var.tags, { Name = "acm-alb-${var.name_prefix}-selfsigned" })

  lifecycle {
    create_before_destroy = true
  }
}

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

  # STRIDE Sprint 6 remediation (Repudiation, flow 1) — see the alb_logs bucket above for the
  # full rationale. No prefix: this ALB is the only thing writing to this bucket, so there's no
  # need to namespace paths within it.
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  tags = merge(var.tags, { Name = "alb-${var.name_prefix}" })

  # Ensures the bucket policy is in place before ELB tries to validate write access to it —
  # without this, the first apply can fail with an access-denied error depending on ordering,
  # same reasoning as modules/aws/cloudtrail's depends_on on aws_cloudtrail.this.
  depends_on = [
    aws_s3_bucket_policy.alb_logs,
    aws_s3_bucket_ownership_controls.alb_logs,
  ]
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

  # Redirects everything to HTTPS (Sprint 6) instead of forwarding — port 80 now exists only to
  # bounce clients onto 443, not to serve anything itself. All the real path-based routing
  # (web default / api on /api/*) lives on the HTTPS listener below.
  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 minimum (Checkov CKV_AWS_103) — this is AWS's recommended baseline policy, works
  # with any client that isn't ancient, no reason to pick anything looser.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = aws_acm_certificate.alb.arn

  # Default action = web, matching Blazor being the "root" experience on Azure too
  # (app-arkcloud-web-dev is the one browsers hit directly).
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
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
