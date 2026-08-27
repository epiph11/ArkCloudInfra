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

output "api_nsg_id" {
  value = azurerm_network_security_group.api.id
}

output "web_nsg_id" {
  value = azurerm_network_security_group.web.id
}

output "database_nsg_id" {
  value = azurerm_network_security_group.database.id
}

output "private_endpoint_nsg_id" {
  value = azurerm_network_security_group.private_endpoint.id
}

# TEMPORARY (Sprint 6 Functions experiment) — null when functions_subnet_prefix isn't set.
output "functions_subnet_id" {
  value = try(azurerm_subnet.functions[0].id, null)
}
