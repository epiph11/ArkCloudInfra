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
  name                 = "st${replace(var.name_prefix, "-", "")}flow"
  resource_group_name  = var.resource_group_name
  location             = var.location
  account_tier         = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = var.tags
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  name                 = "fl-${var.name_prefix}-vnet"
  network_watcher_name = data.azurerm_network_watcher.this.name
  resource_group_name  = data.azurerm_network_watcher.this.resource_group_name

  target_resource_id = var.vnet_id
  storage_account_id = azurerm_storage_account.flow_logs.id
  enabled             = true
  version             = 2

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
