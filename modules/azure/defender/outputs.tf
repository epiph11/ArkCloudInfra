output "key_vault_pricing_id" {
  value = azurerm_security_center_subscription_pricing.key_vault.id
}

output "automation_export_name" {
  value = azurerm_security_center_automation.export_to_log_analytics.name
}
