output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "api_subnet_id" {
  value = azurerm_subnet.api.id
}

output "web_subnet_id" {
  value = azurerm_subnet.web.id
}

output "database_subnet_id" {
  value = azurerm_subnet.database.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.private_endpoint.id
}
