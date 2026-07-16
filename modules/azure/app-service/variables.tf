variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "plan_name" {
  type = string
}

variable "sku_name" {
  description = "e.g. B1 (dev), P1v3 (staging/prod)."
  type        = string
  default     = "B1"
}

variable "app_name" {
  description = "Globally unique — becomes <app_name>.azurewebsites.net."
  type        = string
}

variable "vnet_integration_subnet_id" {
  description = "From the network module — pass network.api_subnet_id for ArkCloud.API (needs to reach PostgreSQL) or network.web_subnet_id for ArkCloud.Blazor (this module is instantiated once per app, each with its own dedicated subnet — Azure ties one VNet-integration subnet to one App Service Plan)."
  type        = string
}

# --- Container image source. Deliberately split into registry/name/tag rather than one
# hardcoded string: swapping GHCR for JFrog Artifactory later (Sprint 4/5, per
# docs/infra-roadmap.md) means changing these three values, not the module. ---
variable "container_registry_url" {
  type    = string
  default = "https://ghcr.io"
}

variable "container_registry_username" {
  description = "Empty for GHCR public images. Required once JFrog (private) replaces it."
  type        = string
  default     = ""
}

variable "container_registry_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "container_image_name" {
  description = "e.g. your-org/arkcloud-api."
  type        = string
}

variable "container_image_tag" {
  type    = string
  default = "latest"
}

variable "key_vault_uri" {
  type = string
}

variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}

variable "extra_app_settings" {
  description = "Any additional app settings beyond the baseline ones this module always sets."
  type        = map(string)
  default     = {}
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "health_check_eviction_time_in_min" {
  description = "Minutes an unhealthy instance stays out of rotation before being reconsidered. Azure allows 2-10."
  type        = number
  default     = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
