output "detector_id" {
  value = aws_guardduty_detector.this.id
}

output "detector_arn" {
  value = aws_guardduty_detector.this.arn
}

# Consommé par le root module pour construire le statement de politique SNS qui autorise
# EventBridge à publier sur le topic d'alertes — scopé via aws:SourceArn à cette règle précise.
output "event_rule_arn" {
  value = aws_cloudwatch_event_rule.findings.arn
}
