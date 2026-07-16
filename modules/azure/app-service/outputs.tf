output "id" {
  value = azurerm_linux_web_app.this.id
}

output "default_hostname" {
  value = azurerm_linux_web_app.this.default_hostname
}

output "principal_id" {
  description = "System-assigned identity's object id — feed into modules/azure/identity's principal_id to grant Key Vault access."
  value       = azurerm_linux_web_app.this.identity[0].principal_id
}
