output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "api_target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "web_target_group_arn" {
  value = aws_lb_target_group.web.arn
}

output "alb_logs_bucket_name" {
  description = "S3 bucket receiving ALB access logs (STRIDE Sprint 6 remediation — see main.tf)."
  value       = aws_s3_bucket.alb_logs.id
}
