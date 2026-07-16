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
