output "trail_arn" {
  value = aws_cloudtrail.this.arn
}

output "bucket_name" {
  value = aws_s3_bucket.trail.id
}

output "notifications_sns_topic_arn" {
  value = aws_sns_topic.trail_notifications.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.trail.name
}
