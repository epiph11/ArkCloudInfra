variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\" — used to derive the storage account name (hyphens stripped, storage account names can't contain them)."
  type        = string
}

variable "network_watcher_name" {
  description = "Azure auto-creates a Network Watcher per region the first time a VNet is created there (\"NetworkWatcher_<region>\" in resource group \"NetworkWatcherRG\") — this module references that existing one via a data source rather than creating a second, to avoid a naming collision. Override only if your subscription's auto-created Network Watcher uses a non-default name (check with `az network watcher list`)."
  type        = string
  default     = null
}

variable "network_watcher_resource_group_name" {
  type    = string
  default = "NetworkWatcherRG"
}

variable "vnet_id" {
  description = "Resource ID of the VNet to enable flow logging on (module.network.vnet_id). As of June 30 2025, Azure no longer supports creating flow logs scoped to a Network Security Group — Virtual Network Flow Logs (this) are the only currently-creatable option, and cover every subnet/NIC under the VNet in one resource rather than one per NSG."
  type        = string
}

variable "retention_days" {
  description = "90 days (Checkov CKV_AZURE_12's benchmark for NSG/VNet flow log retention) rather than the 30-day window used elsewhere (CloudWatch Logs, App Service diagnostics) — deliberately diverges because Standard LRS blob storage is cheap enough per GB that 3x the retention window is a rounding error in cost, unlike CloudWatch Logs Insights or Log Analytics ingestion, so there's no real tradeoff to make here."
  type        = number
  default     = 90
}

variable "enable_traffic_analytics" {
  description = "Traffic Analytics processes flow log data into actual queryable Log Analytics tables (topology, traffic patterns) instead of leaving raw JSON sitting in blob storage — genuinely useful, but it's billed per GB processed on top of the flow logs themselves. Defaults to false to avoid an open-ended recurring cost without a concrete need for it yet; flip to true (and set log_analytics_workspace_guid/log_analytics_workspace_resource_id) once there's an actual reason to query this data rather than just retain it for incident forensics."
  type        = bool
  default     = false
}

variable "log_analytics_workspace_guid" {
  description = "Required only if enable_traffic_analytics = true. The workspace's own GUID (module.monitoring.log_analytics_workspace_guid), not its ARM resource ID."
  type        = string
  default     = null
}

variable "log_analytics_workspace_resource_id" {
  description = "Required only if enable_traffic_analytics = true. The workspace's ARM resource ID (module.monitoring.log_analytics_workspace_id)."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
