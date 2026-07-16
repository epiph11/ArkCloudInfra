variable "location" {
  type    = string
  default = "westeurope"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "tags" {
  description = "Extra tags merged on top of the standard environment/project/managed-by tags (see locals.tf)."
  type        = map(string)
  default     = {}
}

# --- PostgreSQL ---

variable "postgres_admin_login" {
  type      = string
  sensitive = true
  default   = "arkcloudadmin"
}

variable "postgres_admin_password" {
  description = "Never put a literal value here or in terraform.tfvars — supply via TF_VAR_postgres_admin_password (local) or a CI secret (pipeline)."
  type        = string
  sensitive   = true
}

variable "postgres_sku" {
  description = "B_Standard_B1ms (burstable, cheapest) for dev. Use GP_Standard_D2s_v3 or similar for staging/prod."
  type        = string
  default     = "B_Standard_B1ms"
}

# --- App Service ---

variable "app_service_sku" {
  description = "B1 (Basic) for dev — no auto-scale, no SLA. Use P1v3 or higher for staging/prod."
  type        = string
  default     = "B1"
}

# --- Container images ---

variable "image_org" {
  description = "GitHub org/user that owns the GHCR images pushed by arkcloud-backend-ci.yml/arkcloud-frontend-ci.yml, e.g. \"epiphane\" for ghcr.io/epiphane/arkcloud-api. No default on purpose — must be set explicitly per repo."
  type        = string
}

variable "api_image_tag" {
  description = "ArkCloud.API image tag to deploy — \"latest\" for a first apply, a commit SHA or semver tag once CI publishes those."
  type        = string
  default     = "latest"
}

variable "web_image_tag" {
  description = "ArkCloud.Blazor image tag to deploy. Kept independent from api_image_tag on purpose: the cross-repo deploy trigger (see ArkCloudInfra/README.md §7) updates one app's tag at a time via `-target`, and a single shared variable would make an API-only deploy silently reset Blazor's tag back to this variable's default (or vice versa)."
  type        = string
  default     = "latest"
}
