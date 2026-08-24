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

variable "azure_alarm_email" {
  description = "Optional — receives the cost-guard's 80% warning and 100%/action-triggered notifications (see modules/azure/cost-guard). Left unset by default so it stays out of version control; set via TF_VAR_azure_alarm_email or terraform.tfvars if wanted."
  type        = string
  default     = null
}

variable "azure_budget_amount_eur" {
  description = "Monthly EUR threshold scoped to the dev resource group — at 100% actual spend, the cost-guard runbook stops PostgreSQL Flexible Server automatically (modules/azure/cost-guard)."
  type        = number
  default     = 7
}

variable "azure_budget_start_date" {
  description = "First day of a month, RFC3339 — Azure budgets require this to align to the Monthly time_grain and it's effectively immutable after creation. Update to the first of the current month before the first apply of this module."
  type        = string
  default     = "2026-08-01T00:00:00Z"
}

variable "azure_enable_traffic_analytics" {
  description = "Off by default — Traffic Analytics (modules/azure/flow-logs) makes NSG flow logs queryable in Log Analytics instead of raw JSON sitting in blob storage, but bills per GB processed on top of the flow logs themselves. Flip to true once there's an actual reason to query this data."
  type        = bool
  default     = false
}

variable "aws_rotation_interval_days" {
  description = "How often the RDS PostgreSQL password rotates automatically (modules/aws/secret-rotation). Kept equal to azure_rotation_interval_days on purpose — one rotation policy across both clouds, not two that drift apart."
  type        = number
  default     = 90
}

variable "azure_rotation_interval_days" {
  description = "How often the PostgreSQL admin password rotates automatically (modules/azure/secret-rotation). 90 days is the common enterprise baseline; the AWS side uses the same interval via Secrets Manager's native rotation."
  type        = number
  default     = 90
}

variable "azure_rotation_start_time" {
  description = "RFC3339 UTC timestamp for the first scheduled rotation. Azure rejects a start time less than ~5 minutes in the future, so this must be bumped to a future date if the first apply happens after it has passed. Pick an off-peak hour: each rotation briefly restarts the API App Service."
  type        = string
  default     = "2026-09-01T03:00:00Z"
}

variable "aws_alarm_email" {
  description = "Optional — subscribes this address to the CloudWatch alarms SNS topic (task #37). AWS emails a confirmation link on apply that must be clicked before delivery starts. Left unset by default (no default value here, deliberately not hardcoded) so it stays out of version control; set via TF_VAR_aws_alarm_email or terraform.tfvars if wanted."
  type        = string
  default     = null
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

# --- Détection de menaces (Sprint 6) ---

variable "azure_defender_alert_email" {
  description = "Optionnel — reçoit les notifications de Microsoft Defender for Cloud (modules/azure/defender). Laissé non défini par défaut pour ne pas apparaître dans le contrôle de version ; à définir via TF_VAR_azure_defender_alert_email ou terraform.tfvars."
  type        = string
  default     = null
}

variable "azure_defender_alert_phone" {
  description = "Optionnel — numéro joignable par Microsoft pour une alerte Defender critique. Laissé non défini par défaut (donnée personnelle, jamais committée) ; à définir via TF_VAR_azure_defender_alert_phone ou terraform.tfvars si souhaité."
  type        = string
  default     = null
}

variable "azure_enable_defender_app_service" {
  description = "Défaut false — Defender for App Service coûte ~14,60 $/instance/mois (2 App Services ici = ~29 $/mois), largement au-dessus du plafond cost-guard de 7 €/mois. Voir modules/azure/defender/variables.tf pour le détail. À activer pour staging/prod."
  type        = bool
  default     = false
}

variable "azure_enable_defender_databases" {
  description = "Défaut false — même arbitrage budgétaire que azure_enable_defender_app_service, pour le plan Defender for Databases (PostgreSQL Flexible Server)."
  type        = bool
  default     = false
}
