# ---------------------------------------------------------------------------
# TEMPORARY — Sprint 6 experiment, not a permanent part of ArkCloudInfra.
#
# What this is: an Azure Functions app (Flex Consumption plan, VNet-integrated) that runs the
# same "create/rotate the arkcloud_app Postgres role" logic as the AWS side's rotation Lambda
# (modules/aws/secret-rotation, target_role = "app"). Built specifically so the project could
# try Azure Functions hands-on — never used anywhere else in ArkCloud/ArkCloudInfra before —
# not because Functions was the chosen long-term fix for Azure's blocked Runbook (it wasn't:
# Automation Runbooks have no free path into a private VNet, see README.md §10, and this
# module doesn't change that fact for the *scheduled rotation* use case).
#
# The plan, agreed before writing any of this: deploy it, invoke it once, watch it actually
# create arkcloud_app on the Azure Postgres server, then tear this whole module down and
# switch to the free Kudu-SSH-based manual rotation as the lasting mechanism. Keep that plan
# in mind reading the choices below — several of them trade a bit of rigor for "get a working
# experiment running quickly" specifically because this is not meant to outlive the experiment.
#
# Real tradeoff, accepted on purpose: storage_authentication_type below uses a connection
# string (storage_access_key ends up in Terraform state) rather than the Function App's own
# managed identity. The identity-based path has a documented chicken-and-egg problem — the
# Function App needs Storage Blob Data Owner on the account to pull its own deployment package,
# but that role assignment can only be created after the Function App (and its identity) exist
# — which trips up first-time Flex Consumption deployments. The connection-string path sidesteps
# that entirely. State is already the sensitive boundary to protect for secrets set via
# Terraform elsewhere in this project (see modules/azure/key-vault's main.tf comment) — nothing
# new in kind, and this resource is deleted at the end of the experiment regardless.
# ---------------------------------------------------------------------------

# Storage account names are globally unique across all of Azure, lowercase alphanumeric only,
# max 24 chars — a random suffix avoids a name collision with someone else's account entirely
# outside this subscription.
resource "random_id" "storage_suffix" {
  byte_length = 4
}

resource "azurerm_storage_account" "this" {
  name                = "stfnexp${random_id.storage_suffix.hex}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier                  = "Standard"
  account_replication_type      = "LRS" # experiment, not production data — cheapest redundancy is fine
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = true # no private endpoint in this experiment, see module header

  tags = var.tags
}

resource "azurerm_storage_container" "deployments" {
  name                  = "function-deployments"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# FC1 = Flex Consumption. Distinct from every azurerm_service_plan elsewhere in this repo
# (modules/azure/app-service uses a regular Plan) — Flex Consumption is its own SKU family.
resource "azurerm_service_plan" "this" {
  name                = "asp-${var.name_prefix}-functions-experiment"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"

  tags = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = "func-${var.name_prefix}-app-role-experiment"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key

  runtime_name    = "python"
  runtime_version = "3.11"

  # Low ceiling on purpose — this is invoked manually a handful of times, not under real load.
  maximum_instance_count = 10
  instance_memory_in_mb  = 2048

  virtual_network_subnet_id = var.subnet_id

  identity {
    type = "SystemAssigned"
  }

  https_only = true

  # App Insights connection wired here (site_config, not app_settings -- that's the field this
  # resource actually reads) after az webapp log tail (404, /logstream unsupported) and
  # az webapp log config (silently stayed "Off") both turned out to be more Flex Consumption
  # tooling gaps rather than something fixable from this side. Reuses the project's existing,
  # already-provisioned App Insights instance (modules/azure/monitoring) -- no new resource.
  site_config {
    application_insights_connection_string = var.application_insights_connection_string
  }

  app_settings = {
    POSTGRES_HOST           = var.postgres_host
    POSTGRES_DB             = var.postgres_database_name
    POSTGRES_ADMIN_USERNAME = var.postgres_admin_username
    KEY_VAULT_URI           = var.key_vault_uri
    ADMIN_SECRET_NAME       = var.admin_connection_string_secret_name
    APP_ROLE_SECRET_NAME    = var.app_role_secret_name
  }

  # No zip_deploy_file here -- real, current bug in the azurerm provider (v4.81.0, still open:
  # github.com/hashicorp/terraform-provider-azurerm/issues/29630): it pushes the code through the
  # old Kudu "api/zipdeploy" endpoint, which Flex Consumption never supported ("The Flex
  # Consumption plan doesn't support zip deployment", learn.microsoft.com/.../deployment-zip-push)
  # -- confirmed here first-hand: the resource create itself succeeds, then this argument fails
  # with a 404/502 trying to reach a deployment endpoint that isn't there for this plan type.
  # Flex Consumption's real deployment path is OneDeploy (api/publish), which the Azure CLI's
  # `az functionapp deployment source config-zip --build-remote true` already speaks correctly --
  # see build.sh and this module's README for the one-time manual step after `terraform apply`.
  # An earlier version of this app_settings block also had SCM_DO_BUILD_DURING_DEPLOYMENT = true,
  # expecting it to trigger Azure's remote build the way it does for classic Function Apps -- the
  # same GitHub issue notes Microsoft's own docs wrongly copy-pasted that setting from the classic
  # docs and it has no effect here either. --build-remote true on the CLI command is what actually
  # triggers the remote pip install now.

  tags = var.tags
}

# Key Vault is RBAC-authorized (modules/azure/key-vault), and RBAC there only scopes to the
# whole vault, not individual secrets — same limitation already noted in
# modules/azure/secret-rotation/main.tf for the Automation Runbook. "Officer" (read+write)
# rather than "User" (read-only) because this function both reads the admin connection string
# and writes the new arkcloud_app one.
resource "azurerm_role_assignment" "function_key_vault" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}
