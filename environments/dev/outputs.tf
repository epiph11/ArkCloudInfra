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
