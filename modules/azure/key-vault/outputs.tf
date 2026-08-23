output "id" {
  value = azurerm_key_vault.this.id
}

output "vault_uri" {
  description = "Feed this straight into ArkCloud.API's KeyVault:Uri app setting."
  value       = azurerm_key_vault.this.vault_uri
}

output "name" {
  description = "Bare vault name (not the URI) — what Set-AzKeyVaultSecret/az keyvault take as -VaultName. Used by modules/azure/secret-rotation's runbook."
  value       = azurerm_key_vault.this.name
}
