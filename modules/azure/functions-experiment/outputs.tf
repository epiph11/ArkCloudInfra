output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "default_hostname" {
  description = "e.g. func-arkcloud-dev-app-role-experiment.azurewebsites.net — base URL for invoking the HTTP trigger."
  value       = azurerm_function_app_flex_consumption.this.default_hostname
}

output "principal_id" {
  value = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}
