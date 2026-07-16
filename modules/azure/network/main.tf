resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

# --- API subnet: delegated to Microsoft.Web/serverFarms, used exclusively by
# ArkCloud.API's App Service Plan for VNet integration (outbound to PostgreSQL). The only
# subnet allowed to reach the database subnet — see nsg-database below. ---
resource "azurerm_subnet" "api" {
  name                 = "snet-api"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.api_subnet_prefix]

  delegation {
    name = "app-service-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- Web subnet: delegated to Microsoft.Web/serverFarms, used exclusively by
# ArkCloud.Blazor's App Service Plan. Separate from snet-api because a VNet-integration
# subnet belongs to exactly one App Service Plan — and kept out of the database NSG's
# allow-list on purpose: Blazor Server talks to PostgreSQL only indirectly, through
# ArkCloud.API's HTTP endpoints, never directly. ---
resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.web_subnet_prefix]

  delegation {
    name = "app-service-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- Database subnet: delegated to Microsoft.DBforPostgreSQL/flexibleServers so the
# PostgreSQL Flexible Server can use private (VNet-integrated) access instead of a public
# endpoint. ---
resource "azurerm_subnet" "database" {
  name                 = "snet-database"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.database_subnet_prefix]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- Reserved for private endpoints (Key Vault, storage) — no delegation needed, just IPs. ---
resource "azurerm_subnet" "private_endpoint" {
  name                 = "snet-private-endpoint"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_prefix]
}

# --- NSG: API subnet. No custom rules — Azure's default rules already deny inbound from
# Internet and allow outbound (VNet integration is outbound-only anyway, nothing ever
# listens for inbound traffic on this subnet). Left as an explicit resource, empty for now,
# so Sprint 6 hardening has a concrete place to add egress restrictions (e.g. only to the
# database subnet and the image registry) instead of relying purely on defaults. ---
resource "azurerm_network_security_group" "api" {
  name                = "nsg-api"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "api" {
  subnet_id                 = azurerm_subnet.api.id
  network_security_group_id = azurerm_network_security_group.api.id
}

# --- NSG: web subnet. Explicit deny on outbound 5432 — defense in depth so "Blazor never
# talks to PostgreSQL directly" is a network fact, not just a convention the code happens to
# follow today. ---
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "DenyOutboundToDatabase"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "*"
    destination_address_prefix = var.database_subnet_prefix
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

# --- NSG: database subnet — PostgreSQL (5432) only from the API subnet. Neither the web
# subnet nor anything else can reach it; this is the real enforcement point for "backend
# and frontend are not the same trust tier" — not the subnet split itself. ---
resource "azurerm_network_security_group" "database" {
  name                = "nsg-database"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "AllowPostgresFromApi"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.api_subnet_prefix
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "database" {
  subnet_id                 = azurerm_subnet.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}
