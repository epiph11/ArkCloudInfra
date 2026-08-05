output "trail_arn" {
  value = aws_cloudtrail.this.arn
}

output "bucket_name" {
  value = aws_s3_bucket.trail.id
}
