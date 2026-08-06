data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Bucket name must be globally unique across all of AWS — account ID makes that guaranteed
# without needing a random suffix.
resource "aws_s3_bucket" "trail" {
  bucket = "arkcloud-cloudtrail-${var.name_prefix}-${data.aws_caller_identity.current.account_id}"

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# AES256 (SSE-S3, AWS-managed key) rather than a customer-managed KMS key — same "managed key
# is enough for a dev-tier bucket" reasoning already applied to RDS storage encryption
# elsewhere in this project (CKV_AWS_35/CKV_AWS_145 skipped in terraform-ci.yml for the same
# reason). Revisit for prod if compliance requires customer-managed keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CKV_AWS_21 — versioning protects the audit trail itself against accidental or malicious
# overwrite/delete, which is worth the near-zero cost even for a dev-tier bucket (unlike most
# other dev-tier skip decisions in this project, this one's about protecting an audit record,
# not just resource availability).
resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# CKV2_AWS_61 — expires old log objects so storage cost doesn't grow unbounded. 90 days is a
# dev-tier retention window (matches this project's general "no compliance mandate yet"
# posture) — extend for staging/prod if a real retention requirement shows up later.
resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    # CKV_AWS_300 — without this, a failed/abandoned multipart upload (e.g. an interrupted
    # CloudTrail log delivery) leaves orphaned parts billed as storage forever, since they're
    # invisible to the object-level expiration rule above.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CKV_AWS_252 — CloudTrail can publish a notification to this topic every time it delivers a
# new log file to the bucket. Kept as its own dedicated topic rather than reusing
# modules/aws/monitoring's alerts topic — CloudTrail log delivery isn't an alert condition
# (this fires on every single delivery, several times an hour), and mixing the two would mean
# either spamming the alerts topic or losing the log-delivery signal entirely.
resource "aws_sns_topic" "trail_notifications" {
  name = "arkcloud-cloudtrail-${var.name_prefix}"
  tags = var.tags

  # CKV_AWS_26 — AWS-managed key (no extra KMS resource/cost), same "managed key is enough for
  # dev" call already made for RDS/Secrets Manager/ECR/CloudWatch Logs elsewhere in this project.
  kms_master_key_id = "alias/aws/sns"
}

data "aws_iam_policy_document" "trail_sns" {
  statement {
    sid    = "AWSCloudTrailSNSPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.trail_notifications.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/arkcloud-trail-${var.name_prefix}"]
    }
  }
}

resource "aws_sns_topic_policy" "trail_notifications" {
  arn    = aws_sns_topic.trail_notifications.arn
  policy = data.aws_iam_policy_document.trail_sns.json
}

# CKV2_AWS_10 — streams the same trail events to CloudWatch Logs (in addition to S3), so they're
# searchable/alertable alongside the application logs already flowing there from ECS. CloudTrail
# needs its own IAM role to assume for this delivery — distinct from the S3 bucket policy above,
# which only covers writing to S3.
resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/arkcloud-${var.name_prefix}"
  retention_in_days = 90

  tags = var.tags
}

data "aws_iam_policy_document" "trail_cwl_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "trail_cwl" {
  name               = "arkcloud-cloudtrail-cwl-${var.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.trail_cwl_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "trail_cwl_delivery" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}

resource "aws_iam_role_policy" "trail_cwl" {
  name   = "cloudwatch-logs-delivery"
  role   = aws_iam_role.trail_cwl.id
  policy = data.aws_iam_policy_document.trail_cwl_delivery.json
}

# Standard AWS-documented CloudTrail bucket policy (see
# https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html) —
# the service needs to read the bucket ACL and write objects under an AWSLogs/<account-id>/
# prefix, scoped via aws:SourceArn to this specific trail so no other account/trail can write
# here. The s3:x-amz-acl condition below matches AWS's own current template exactly — an
# earlier revision of this module removed it on the theory that it'd conflict with this
# bucket's BucketOwnerEnforced setting, which was wrong (confirmed by comparing against AWS's
# live documentation): the header CloudTrail sends is independent of the bucket's ACL/Object
# Ownership setting, so this condition is safe on a no-ACL bucket. The bug that actually caused
# CreateTrail's "Incorrect S3 bucket policy" error was a wildcard region ("cloudtrail:*:...")
# in the SourceArn condition below — this is a single-region trail, and CloudTrail's policy
# validator wants the exact region to match, not a wildcard.
data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/arkcloud-trail-${var.name_prefix}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/arkcloud-trail-${var.name_prefix}"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

# Single-region (eu-west-1 only, via the current provider's configured region) — this is a
# dev-tier, single-region deployment (see Step 10's network module), so a multi-region trail
# (CKV_AWS_67) would only add duplicate delivery cost with nothing extra to actually audit.
# Revisit if/when staging/prod span multiple regions.
resource "aws_cloudtrail" "this" {
  name           = "arkcloud-trail-${var.name_prefix}"
  s3_bucket_name = aws_s3_bucket.trail.id

  sns_topic_name = aws_sns_topic.trail_notifications.name

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail_cwl.arn

  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  tags = var.tags

  depends_on = [
    aws_s3_bucket_policy.trail,
    aws_s3_bucket_ownership_controls.trail,
    aws_sns_topic_policy.trail_notifications,
    aws_iam_role_policy.trail_cwl,
  ]
}
