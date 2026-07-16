# Private DNS zone required for PostgreSQL Flexible Server private (VNet-integrated) access —
# without it, the server falls back to requiring a public endpoint.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.server_name}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.server_name}-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = var.virtual_network_id
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version    = var.postgresql_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  delegated_subnet_id    = var.delegated_subnet_id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id

  # Azure refuses public network access and VNet-integrated private access at the same time —
  # the provider defaults this to true, which conflicts with delegated_subnet_id above.
  public_network_access_enabled = false

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled
  auto_grow_enabled            = var.storage_auto_grow_enabled

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    # Password rotation should go through a separate, deliberate change — not an incidental
    # side effect of an unrelated `terraform apply` picking up a stale var value.
    ignore_changes = [administrator_password]
  }
}

# SSL/TLS is enforced by default on Flexible Server (require_secure_transport = ON) — no
# extra resource needed to turn it on, just documenting that it's already the case.

resource "azurerm_postgresql_flexible_server_database" "arkcloud" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "utf8"
}
