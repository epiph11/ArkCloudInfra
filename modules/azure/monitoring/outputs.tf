output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "instrumentation_key" {
  value     = azurerm_application_insights.this.instrumentation_key
  sensitive = true
}

output "connection_string" {
  description = "Feed straight into ArkCloud.API's APPLICATIONINSIGHTS_CONNECTION_STRING app setting."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}
