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
