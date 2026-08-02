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
  description = "ArkCloud.API image tag to deploy. Default matches whatever arkcloud-backend-ci.yml actually publishes for the dev branch (\"dev\") — NOT \"latest\", which GHCR has never had a tag for. This default is also what the full terraform-ci.yml apply job falls back to on every push to main, so it must stay in sync with reality or it will silently overwrite whatever tag the §7 cross-repo dispatch (-target, explicit -var) last deployed."
  type        = string
  default     = "dev"
}

variable "web_image_tag" {
  description = "ArkCloud.Blazor image tag to deploy. Kept independent from api_image_tag on purpose: the cross-repo deploy trigger (see ArkCloudInfra/README.md §7) updates one app's tag at a time via `-target`, and a single shared variable would make an API-only deploy silently reset Blazor's tag back to this variable's default (or vice versa). Default matches arkcloud-frontend-ci.yml's actual dev-branch publish tag (\"dev\") for the same reason as api_image_tag above — \"latest\" was never a real published tag."
  type        = string
  default     = "dev"
}

variable "ghcr_username" {
  description = "GitHub username/org owning the GHCR packages — used only as the Docker registry login, distinct from image_org in case they ever diverge."
  type        = string
  default     = "epiph11"
}

variable "ghcr_pat" {
  description = "GitHub PAT scoped to read:packages only, used solely so App Service can authenticate to ghcr.io — packages here are not guaranteed to stay public, and a real credential is more durable than depending on a visibility toggle. Never put a literal value here or in terraform.tfvars — supply via TF_VAR_ghcr_pat (local) or a CI secret (pipeline)."
  type        = string
  sensitive   = true
}

# --- AWS (Sprint 5) ---

variable "aws_region" {
  description = "Kept as a variable (not just hardcoded in providers.tf's provider block) so modules that need to build ARNs/endpoint URLs referencing the region don't have to re-derive it from a data source."
  type        = string
  default     = "eu-west-1"
}

variable "aws_azs" {
  description = "Exactly two — matches modules/aws/vpc's public/ecs/database subnet pairs. eu-west-1a/b chosen arbitrarily; eu-west-1 has a third (1c) not used here."
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

# --- AWS RDS PostgreSQL (Sprint 5, Step 12) ---

variable "aws_postgres_admin_login" {
  type      = string
  sensitive = true
  default   = "arkcloudadmin"
}

variable "aws_postgres_admin_password" {
  description = "Never put a literal value here or in terraform.tfvars — supply via TF_VAR_aws_postgres_admin_password (local) or a CI secret (pipeline). Kept separate from postgres_admin_password (Azure): each cloud's credential rotates independently."
  type        = string
  sensitive   = true
}

variable "aws_postgres_instance_class" {
  description = "db.t3.micro (burstable, cheapest) for dev — mirrors postgres_sku's B_Standard_B1ms on the Azure side. Use a larger, non-burstable class for staging/prod."
  type        = string
  default     = "db.t3.micro"
}
