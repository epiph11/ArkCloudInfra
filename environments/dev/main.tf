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

  container_registry_url      = "https://ghcr.io"
  container_registry_username = var.ghcr_username
  container_registry_password = var.ghcr_pat

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

  container_registry_url      = "https://ghcr.io"
  container_registry_username = var.ghcr_username
  container_registry_password = var.ghcr_pat

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

# ---------------------------------------------------------------------------
# Audit / diagnostic logging — Step 17 checklist item ("Audit logging activé").
# ---------------------------------------------------------------------------
# Until now, Log Analytics only received *application* telemetry (App Insights SDK, see
# README §5 point 6) — nothing at the platform level. These four diagnostic settings route
# Key Vault access events, PostgreSQL server logs, and both App Services' platform/HTTP logs
# into the same workspace, so an actual audit trail exists for "who read which secret" /
# "what hit the database" / "what did each App Service serve", not just app-level requests.
#
# `category_group = "allLogs"` (rather than enumerating individual categories like
# "AuditEvent" or "AppServiceHTTPLogs") is deliberate: it's the modern azurerm v4 shorthand
# for "every log category this resource type currently exposes," so this doesn't silently
# stop capturing a category if Azure renames/adds one later.
#
# NOT included here: NSG flow logs. Those need Network Watcher + a Storage Account
# (azurerm_network_watcher_flow_log), which is meaningfully more infrastructure than a
# diagnostic setting on an existing resource — left for Sprint 6 hardening rather than
# folded into this pass.

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-arkcloud-${var.environment}"
  target_resource_id         = module.key_vault.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  name                       = "diag-psql-arkcloud-${var.environment}"
  target_resource_id         = module.postgresql.server_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "app_service_api" {
  name                       = "diag-app-arkcloud-api-${var.environment}"
  target_resource_id         = module.app_service_api.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # Bug réel trouvé au premier test end-to-end (28/07) : sans ce réglage, Terraform crée le
  # diagnostic setting en mode legacy "Azure Diagnostics" (une seule table AzureDiagnostics
  # partagée par tout, filtrée par ResourceProvider/Category). Ça a marché en quelques minutes
  # pour Key Vault (AuditEvent) et PostgreSQL (PostgreSQLLogs), mais AUCUNE ligne n'est jamais
  # apparue pour les App Services (AppServiceHTTPLogs/AppServiceConsoleLogs/AppServicePlatformLogs)
  # même après 30 min d'attente et du vrai trafic HTTP généré exprès. Le mode "Azure Diagnostics"
  # est documenté par Microsoft comme le pipeline le moins fiable spécifiquement pour
  # Microsoft.Web/sites — "Dedicated" (tables dédiées, une par catégorie) est le mode recommandé
  # pour ce type de ressource. Changer cet attribut force un remplacement du diagnostic setting
  # (delete+create), pas un update en place — normal, pas une erreur au prochain plan/apply.
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# AWS (Sprint 5) — same environments/dev root module and state file as Azure above, per
# docs/infra-roadmap.md's multi-cloud decision: one `terraform apply` provisions both clouds
# rather than splitting into a second root module to keep in sync by hand.
# ---------------------------------------------------------------------------

module "aws_vpc" {
  source = "../../modules/aws/vpc"

  name_prefix = "arkcloud-${var.environment}"
  azs         = var.aws_azs

  tags = local.common_tags
}

module "aws_security" {
  source = "../../modules/aws/security"

  name_prefix = "arkcloud-${var.environment}"
  vpc_id      = module.aws_vpc.vpc_id

  tags = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "app_service_web" {
  name                       = "diag-app-arkcloud-web-${var.environment}"
  target_resource_id         = module.app_service_web.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # Même correctif que app_service_api ci-dessus — voir ce commentaire pour le pourquoi.
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
  }
}
