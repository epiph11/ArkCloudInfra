data "aws_caller_identity" "current" {}

# Bucket name must be globally unique across all of AWS — account ID makes that guaranteed
# without needing a random suffix.
resource "aws_s3_bucket" "trail" {
  bucket = "arkcloud-cloudtrail-${var.name_prefix}-${data.aws_caller_identity.current.account_id}"

  tags = var.tags
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
# elsewhere in this project. Revisit for prod if compliance requires customer-managed keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Standard AWS-documented CloudTrail bucket policy: the service needs to read the bucket ACL
# and write objects under an AWSLogs/<account-id>/ prefix, scoped via aws:SourceArn to this
# specific trail so no other account/trail can write here.
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
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/arkcloud-trail-${var.name_prefix}"]
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
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/arkcloud-trail-${var.name_prefix}"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

# Single-region (eu-west-1 only) — this is a dev-tier, single-region deployment (see Step 10's
# network module), so a multi-region trail would only add duplicate delivery cost with nothing
# extra to actually audit. Revisit if/when staging/prod span multiple regions.
resource "aws_cloudtrail" "this" {
  name           = "arkcloud-trail-${var.name_prefix}"
  s3_bucket_name = aws_s3_bucket.trail.id

  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  tags = var.tags

  depends_on = [aws_s3_bucket_policy.trail]
}
