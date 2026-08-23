output "server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.arkcloud.name
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "administrator_login" {
  description = "Username only — never the password. Needed by modules/azure/secret-rotation to rebuild the connection string after rotating the password."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}
