output "id" {
  value = azurerm_key_vault.this.id
}

output "vault_uri" {
  description = "Feed this straight into ArkCloud.API's KeyVault:Uri app setting."
  value       = azurerm_key_vault.this.vault_uri
}
