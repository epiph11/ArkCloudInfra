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

  # "join/action", pas le générique "action" utilisé pour Microsoft.Web/serverFarms plus haut :
  # c'est la valeur que Microsoft documente pour la délégation PostgreSQL Flexible Server, et
  # surtout celle que le service impose lui-même en s'injectant dans le subnet.
  #
  # Diagnostic établi à partir d'une observation, pas d'une supposition : les trois subnets
  # portaient la même valeur générique, mais seul celui-ci apparaissait en dérive à chaque plan —
  # appliqué, puis revenu, indéfiniment. Azure réécrivait la valeur derrière Terraform, qui la
  # remettait au plan suivant. La config était fausse, la dérive n'était que le symptôme.
  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
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

# --- TEMPORARY (Sprint 6 experiment, see modules/azure/functions-experiment): dedicated subnet
# for an Azure Functions Flex Consumption app's VNet integration. count-gated on
# functions_subnet_prefix being set, rather than always created, so removing the experiment
# later is just deleting the variable's value in environments/dev/main.tf — no HCL to prune here
# and no destroy/recreate risk to the four subnets above. ---
resource "azurerm_subnet" "functions" {
  count                = var.functions_subnet_prefix != null ? 1 : 0
  name                 = "snet-functions"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.functions_subnet_prefix]

  # "join/action" confirmed via Microsoft's own Terraform example for Flex Consumption VNet
  # integration (registry.terraform.io azurerm_function_app_flex_consumption docs) — same action
  # string as the Postgres delegation above, different service_delegation.name.
  delegation {
    name = "functions-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
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

# --- NSG: database subnet — PostgreSQL (5432) only from the API subnet (and, temporarily, the
# Functions experiment subnet below). Neither the web subnet nor anything else can reach it;
# this is the real enforcement point for "backend and frontend are not the same trust tier" —
# not the subnet split itself. ---
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

  # TEMPORARY (Sprint 6 experiment) — a separate named rule rather than turning
  # source_address_prefix above into a list, so removing the experiment later is deleting this
  # one dynamic block, not editing the rule the API depends on. Only materializes when
  # functions_subnet_prefix is set (see azurerm_subnet.functions).
  dynamic "security_rule" {
    for_each = var.functions_subnet_prefix != null ? [1] : []
    content {
      name                       = "AllowPostgresFromFunctionsExperiment"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "5432"
      source_address_prefix      = var.functions_subnet_prefix
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "database" {
  subnet_id                 = azurerm_subnet.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}

# --- NSG: TEMPORARY Functions-experiment subnet. Empty like nsg-api/nsg-private-endpoint —
# outbound is unrestricted by default (needed anyway: Storage/Key Vault traffic leaves this
# subnet over the public internet, only the 10.10.2.0/24 Postgres destination gets routed
# through the VNet automatically because it's an RFC1918 range). ---
resource "azurerm_network_security_group" "functions" {
  count               = var.functions_subnet_prefix != null ? 1 : 0
  name                = "nsg-functions-experiment"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "functions" {
  count                     = var.functions_subnet_prefix != null ? 1 : 0
  subnet_id                 = azurerm_subnet.functions[0].id
  network_security_group_id = azurerm_network_security_group.functions[0].id
}

# --- NSG: private-endpoint subnet. Empty like nsg-api — nothing initiates outbound from here
# and Azure's default rules already deny inbound from the Internet. Exists mainly so Checkov
# (CKV2_AZURE_31: every subnet needs an NSG) doesn't flag this one as the odd one out, and so
# Sprint 6 has a concrete place to add rules once real private endpoints land here. ---
resource "azurerm_network_security_group" "private_endpoint" {
  name                = "nsg-private-endpoint"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "private_endpoint" {
  subnet_id                 = azurerm_subnet.private_endpoint.id
  network_security_group_id = azurerm_network_security_group.private_endpoint.id
}
