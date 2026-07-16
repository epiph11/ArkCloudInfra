resource "azurerm_service_plan" "this" {
  name                = var.plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.sku_name
  tags                = var.tags
}

resource "azurerm_linux_web_app" "this" {
  name                = var.app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id

  https_only = true

  # System-assigned identity — no credential stored anywhere, granted "Key Vault Secrets User"
  # on the vault via modules/azure/identity, consumed by ArkCloud.API's existing
  # DefaultAzureCredential-based Key Vault pattern (Program.cs, already in the app repo).
  identity {
    type = "SystemAssigned"
  }

  virtual_network_subnet_id = var.vnet_integration_subnet_id

  site_config {
    always_on              = true
    minimum_tls_version     = "1.2"
    health_check_path       = var.health_check_path
    # azurerm v4 requires this alongside health_check_path — how long an unhealthy instance
    # stays out of the App Service Plan's load-balancing rotation before being reconsidered.
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min
    vnet_route_all_enabled  = true # outbound traffic (to PostgreSQL) goes over the VNet, not the public internet

    application_stack {
      docker_image_name   = "${var.container_image_name}:${var.container_image_tag}"
      docker_registry_url = var.container_registry_url
      docker_registry_username = var.container_registry_username != "" ? var.container_registry_username : null
      docker_registry_password = var.container_registry_password != "" ? var.container_registry_password : null
    }
  }

  app_settings = merge(
    {
      "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
      "ASPNETCORE_ENVIRONMENT"              = "Production"
      "KeyVault__Uri"                       = var.key_vault_uri
      "APPLICATIONINSIGHTS_CONNECTION_STRING" = var.app_insights_connection_string
    },
    var.extra_app_settings
  )

  logs {
    application_logs {
      file_system_level = "Information"
    }
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  tags = var.tags
}
