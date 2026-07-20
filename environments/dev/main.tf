module "resource_group" {
  source = "../../modules/azure/resource-group"

  name     = "rg-arkcloud-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

module "network" {
  source = "../../modules/azure/network"

  resource_group_name = module.resource_group.name
  location            = var.location
  vnet_name           = "vnet-arkcloud-${var.environment}"
  address_space       = ["10.10.0.0/16"]

  # See ArkCloudInfra/README.md §3 for why api/web are two separate subnets rather than one.
  api_subnet_prefix              = "10.10.1.0/24"
  web_subnet_prefix              = "10.10.4.0/24"
  database_subnet_prefix         = "10.10.2.0/24"
  private_endpoint_subnet_prefix = "10.10.3.0/24"

  tags = local.common_tags
}

module "postgresql" {
  source = "../../modules/azure/postgresql"

  resource_group_name = module.resource_group.name
  location            = var.location
  server_name         = "psql-arkcloud-${var.environment}"
  sku_name            = var.postgres_sku

  administrator_login    = var.postgres_admin_login
  administrator_password = var.postgres_admin_password

  delegated_subnet_id = module.network.database_subnet_id
  virtual_network_id  = module.network.vnet_id

  # geo_redundant_backup_enabled left at its false default — dev doesn't need it, staging/prod will override.
  tags = local.common_tags
}

module "key_vault" {
  source = "../../modules/azure/key-vault"

  resource_group_name = module.resource_group.name
  location            = var.location
  name                = "kv-arkcloud-${var.environment}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/azure/monitoring"

  resource_group_name = module.resource_group.name
  location            = var.location
  log_analytics_name  = "log-arkcloud-${var.environment}"
  app_insights_name   = "appi-arkcloud-${var.environment}"

  tags = local.common_tags
}

# --- ArkCloud.API ---
module "app_service_api" {
  source = "../../modules/azure/app-service"

  resource_group_name = module.resource_group.name
  location            = var.location
  plan_name           = "asp-arkcloud-api-${var.environment}"
  app_name            = "app-arkcloud-api-${var.environment}"
  sku_name            = var.app_service_sku

  vnet_integration_subnet_id = module.network.api_subnet_id

  container_image_name = "${var.image_org}/arkcloud-api"
  container_image_tag  = var.api_image_tag

  key_vault_uri                  = module.key_vault.vault_uri
  app_insights_connection_string = module.monitoring.connection_string

  tags = local.common_tags
}

# The API's identity needs to read secrets from Key Vault — Blazor doesn't (it never touches
# the DB password or the JWT signing key directly), so no equivalent role assignment exists
# for app_service_web below.
module "keyvault_access_api" {
  source = "../../modules/azure/identity"

  scope        = module.key_vault.id
  principal_id = module.app_service_api.principal_id
  # role_definition_name defaults to "Key Vault Secrets User"
}

# --- ArkCloud.Blazor ---
module "app_service_web" {
  source = "../../modules/azure/app-service"

  resource_group_name = module.resource_group.name
  location            = var.location
  plan_name           = "asp-arkcloud-web-${var.environment}"
  app_name            = "app-arkcloud-web-${var.environment}"
  sku_name            = var.app_service_sku

  vnet_integration_subnet_id = module.network.web_subnet_id

  container_image_name = "${var.image_org}/arkcloud-frontend"
  container_image_tag  = var.web_image_tag

  # Blazor doesn't read secrets from Key Vault today, but the module requires the variable —
  # harmless: the app setting just goes unused. Kept for consistency rather than making the
  # module conditionally accept it for one caller.
  key_vault_uri                  = module.key_vault.vault_uri
  app_insights_connection_string = module.monitoring.connection_string

  # Wires Blazor to the API's real hostname without either side hardcoding it.
  extra_app_settings = {
    "Api__BaseUrl" = "https://${module.app_service_api.default_hostname}"
  }

  tags = local.common_tags
}
