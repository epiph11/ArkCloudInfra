# ---------------------------------------------------------------------------
# Virtual Network flow logs — deferred from Sprint 5 (see modules/azure/network's
# diagnostic-logging comment in environments/dev/main.tf), built now as the first Sprint 6
# hardening item.
#
# NOT NSG flow logs, despite the original plan: Azure retired the ability to create *new* NSG
# flow logs on June 30, 2025 (confirmed live against the AzureRM provider docs and Microsoft's
# own migration guide — `network_security_group_id` on this resource errors with "creation of
# new NSG flow logs is no longer supported by Azure" as of that date; existing ones keep working
# until the September 30, 2027 full retirement, but nothing new can target an NSG). Virtual
# Network flow logs are the current replacement: same underlying resource type
# (azurerm_network_watcher_flow_log), just `target_resource_id` pointed at the VNet instead of
# `network_security_group_id` pointed at an NSG — and a bonus simplification, since one VNet-level
# flow log now covers every subnet (api/web/database/private-endpoint) instead of needing one
# resource per NSG.
#
# Records accepted/denied traffic per NSG rule at the VNet level — this is the one audit signal
# the existing diagnostic settings (Key Vault access, PostgreSQL logs, App Service HTTP logs)
# don't cover: none of them show *network-level* traffic that never reached the application
# layer at all (e.g. a port-scan or a blocked connection attempt hitting an NSG deny rule).
#
# Checkov (first run against this module) — 3 fixed below (soft delete, SAS expiration policy,
# 90-day retention), 7 skipped in terraform-ci.yml (README.md §9 has the full list): the two
# recurring themes are (a) public network access / private endpoint — same tradeoff already made
# for Key Vault and the cost-guard Automation Account, a private endpoint is real extra
# infrastructure disproportionate at dev scale, and (b) disabling Shared Key auth, which would
# silently break flow log delivery — Network Watcher only supports AAD-only storage access via a
# user-assigned managed identity, and the azurerm provider has no argument for it yet on
# azurerm_network_watcher_flow_log (open feature request, hashicorp/terraform-provider-azurerm#30219).
# ---------------------------------------------------------------------------

# Azure auto-creates exactly one Network Watcher per region per subscription, the first time a
# VNet is created there — referencing it via data source rather than creating a second
# `azurerm_network_watcher` resource, which would collide on the same region/subscription.
data "azurerm_network_watcher" "this" {
  name                = coalesce(var.network_watcher_name, "NetworkWatcher_${var.location}")
  resource_group_name = var.network_watcher_resource_group_name
}

# Standard LRS — flow logs are write-once JSON blobs read only during an investigation, not a
# performance-sensitive path; no reason to pay for a higher storage tier.
resource "azurerm_storage_account" "flow_logs" {
  name                     = "st${replace(var.name_prefix, "-", "")}flow"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Soft delete (Checkov CKV2_AZURE_38) — pure config, no cost beyond the retained blobs
  # themselves, protects against an accidental delete (fat-fingered `az storage blob delete`,
  # wrong-target Terraform destroy) during the retention window.
  blob_properties {
    delete_retention_policy {
      days = 30
    }
  }

  # SAS expiration policy (Checkov CKV2_AZURE_41) — nothing in this module issues a SAS today,
  # but if the storage key is ever used to hand-generate one for a one-off investigation, this
  # caps how long it stays valid instead of defaulting to "forever". "Log" (not "Block") so it
  # can't break anything Network Watcher itself is doing to write flow logs.
  sas_policy {
    expiration_action = "Log"
    expiration_period = "07.00:00:00"
  }

  tags = var.tags
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  name                 = "fl-${var.name_prefix}-vnet"
  network_watcher_name = data.azurerm_network_watcher.this.name
  resource_group_name  = data.azurerm_network_watcher.this.resource_group_name

  target_resource_id = var.vnet_id
  storage_account_id = azurerm_storage_account.flow_logs.id
  enabled            = true
  version            = 2

  retention_policy {
    enabled = true
    days    = var.retention_days
  }

  dynamic "traffic_analytics" {
    for_each = var.enable_traffic_analytics ? [1] : []
    content {
      enabled               = true
      workspace_id          = var.log_analytics_workspace_guid
      workspace_region      = var.location
      workspace_resource_id = var.log_analytics_workspace_resource_id
      interval_in_minutes   = 60
    }
  }

  tags = var.tags
}
