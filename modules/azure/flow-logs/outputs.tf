output "storage_account_name" {
  value = azurerm_storage_account.flow_logs.name
}

output "network_watcher_name" {
  value = data.azurerm_network_watcher.this.name
}
