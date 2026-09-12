resource "azurerm_linux_web_app" "this" {
  name                = var.app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  # Sprint 6 clôture (12/09) — réduction de coûts : ce module ne crée plus son propre Plan.
  # Les 2 App Services (api + web) partagent désormais UN SEUL azurerm_service_plan (créé dans
  # environments/dev/main.tf) au lieu d'un chacun — ~12€/mois économisés (2× B1 → 1× B1, Azure
  # facture le Plan à l'heure d'existence, peu importe le nombre d'apps dessus).
  #
  # Compromis documenté (STRIDE flux 3, tâche #69) : Azure n'autorise qu'UN SEUL subnet de
  # VNet integration par Plan — partager le Plan oblige donc web et api à partager le même
  # subnet (snet-api), donc le même NSG. Le blocage réseau "DenyOutboundToDatabase" de nsg-web
  # ne s'applique plus à Blazor. Mitigations restantes, toutes non-réseau : (1) Blazor n'appelle
  # jamais Postgres dans le code — vérifié, aucun DbContext/connection string injecté côté
  # ArkCloud.Blazor ; (2) même si un appel existait, PostgreSQL n'accepte que le rôle
  # arkcloud_app, jamais présenté à Blazor ; (3) nsg-database continue de n'autoriser que
  # source_address_prefix = snet-api, donc la surface réseau reste identique à avant, seule la
  # distinction web/api À L'INTÉRIEUR de ce subnet disparaît. Voir docs/adr/ pour la mise à jour
  # du threat model flux 3.
  service_plan_id = var.service_plan_id

  https_only = true

  # System-assigned identity — no credential stored anywhere, granted "Key Vault Secrets User"
  # on the vault via modules/azure/identity, consumed by ArkCloud.API's existing
  # DefaultAzureCredential-based Key Vault pattern (Program.cs, already in the app repo).
  identity {
    type = "SystemAssigned"
  }

  # "Optional" (not "Required") — this stays a normal HTTPS site for browsers/API callers, no
  # mTLS enforced. Satisfies Checkov's CKV_AZURE_17 without breaking normal client access.
  client_certificate_enabled = true
  client_certificate_mode    = "Optional"

  virtual_network_subnet_id = var.vnet_integration_subnet_id

  site_config {
    always_on           = true
    minimum_tls_version = "1.2"
    http2_enabled       = true
    # FTP/FTPS deployment isn't part of our deploy path at all (images come from GHCR via
    # Terraform) — disabling it removes a credentialed access surface nobody uses.
    ftps_state        = "Disabled"
    health_check_path = var.health_check_path
    # azurerm v4 requires this alongside health_check_path — how long an unhealthy instance
    # stays out of the App Service Plan's load-balancing rotation before being reconsidered.
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min
    vnet_route_all_enabled            = true # outbound traffic (to PostgreSQL) goes over the VNet, not the public internet

    application_stack {
      docker_image_name        = "${var.container_image_name}:${var.container_image_tag}"
      docker_registry_url      = var.container_registry_url
      docker_registry_username = var.container_registry_username != "" ? var.container_registry_username : null
      docker_registry_password = var.container_registry_password != "" ? var.container_registry_password : null
    }
  }

  app_settings = merge(
    {
      "WEBSITES_ENABLE_APP_SERVICE_STORAGE"   = "false"
      "ASPNETCORE_ENVIRONMENT"                = "Production"
      "KeyVault__Uri"                         = var.key_vault_uri
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
    # Local, App Service-retained diagnostics — no separate storage account needed. Detailed
    # error pages and failed-request traces are invaluable when something 500s and App Insights
    # alone doesn't explain why. Plain boolean attributes on azurerm_linux_web_app's current
    # schema — NOT sub-blocks (first attempt used `detailed_error_messages { enabled = true }`,
    # which terraform validate rejects: "Unsupported block type").
    detailed_error_messages = true
    failed_request_tracing  = true
  }

  tags = var.tags

  # Bug réel, confirmé deux fois en production (Sprint 6, 28-30/08/2026) :
  # application_stack.docker_registry_password ne se propage pas de façon fiable au
  # sous-système réel de pull de conteneur de l'App Service (hashicorp/terraform-provider-azurerm
  # #22996, #23525). Le correctif qui marche vraiment est hors-Terraform, via
  # `az webapp config container set` (voir scripts/rotate-ghcr-pat.ps1, étape 4). Un essai
  # antérieur pour forcer les clés DOCKER_REGISTRY_SERVER_* dans app_settings a été rejeté par le
  # provider lui-même à `terraform plan` ("cannot set a value for ... in app_settings" dès que
  # application_stack est utilisé) — donc pas une option.
  #
  # Sans ce ignore_changes, CHAQUE apply qui touche cette ressource pour une raison quelconque
  # (même sans rapport avec le registre) réapplique application_stack.docker_registry_password
  # via le chemin buggé et écrase silencieusement le correctif hors-bande — provoquant une vraie
  # panne de pull d'image. Constaté en direct : le commit 224d057 (qui ne touchait qu'un revert
  # de app_settings, rien lié au registre) a suffi à recasser le pull sur app-arkcloud-api-dev.
  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker_registry_password]
  }
}
