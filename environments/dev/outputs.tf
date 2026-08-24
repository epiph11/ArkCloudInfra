output "api_hostname" {
  value = module.app_service_api.default_hostname
}

output "web_hostname" {
  value = module.app_service_web.default_hostname
}

output "postgres_fqdn" {
  value = module.postgresql.fqdn
}

output "key_vault_uri" {
  value = module.key_vault.vault_uri
}

output "resource_group_name" {
  value = module.resource_group.name
}

output "azure_cost_guard_runbook_name" {
  value = module.azure_cost_guard.runbook_name
}

output "azure_cost_guard_budget_name" {
  value = module.azure_cost_guard.budget_name
}

output "azure_flow_logs_storage_account" {
  value = module.flow_logs.storage_account_name
}

output "aws_secret_rotation_lambda_name" {
  value = module.aws_secret_rotation.lambda_function_name
}

output "azure_secret_rotation_runbook_name" {
  value = module.azure_secret_rotation.runbook_name
}

output "azure_secret_rotation_automation_account" {
  value = module.azure_secret_rotation.automation_account_name
}

# --- AWS (Sprint 5) ---

output "aws_vpc_id" {
  value = module.aws_vpc.vpc_id
}

output "aws_ecs_subnet_ids" {
  value = module.aws_vpc.ecs_subnet_ids
}

output "aws_database_subnet_ids" {
  value = module.aws_vpc.database_subnet_ids
}

output "aws_postgres_endpoint" {
  value = module.aws_rds.endpoint
}

output "aws_postgres_database_name" {
  value = module.aws_rds.database_name
}

output "aws_postgres_secret_arn" {
  value = module.aws_secrets.postgres_secret_arn
}

output "aws_jwt_secret_arn" {
  value = module.aws_secrets.jwt_secret_arn
}

output "aws_ecr_api_repository_url" {
  value = module.aws_ecr.api_repository_url
}

output "aws_ecr_web_repository_url" {
  value = module.aws_ecr.web_repository_url
}

output "aws_ecs_cluster_name" {
  value = module.aws_ecs.cluster_name
}

output "aws_alb_dns_name" {
  value = module.aws_alb.alb_dns_name
}

output "aws_monitoring_dashboard_name" {
  value = module.aws_monitoring.dashboard_name
}

output "aws_alerts_sns_topic_arn" {
  value = module.aws_monitoring.sns_topic_arn
}

output "aws_cloudtrail_bucket_name" {
  value = module.aws_cloudtrail.bucket_name
}

output "aws_guardduty_detector_id" {
  value = module.aws_guardduty.detector_id
}

output "azure_defender_automation_export_name" {
  value = module.azure_defender.automation_export_name
}
