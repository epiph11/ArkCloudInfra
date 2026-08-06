output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_guid" {
  description = "The workspace's own GUID (workspace_id attribute) — distinct from the ARM resource ID above. Traffic Analytics (modules/azure/flow-logs) needs both: this for its `workspace_id` argument, the ARM resource ID for `workspace_resource_id`."
  value       = azurerm_log_analytics_workspace.this.workspace_id
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
