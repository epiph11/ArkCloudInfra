variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  description = "Scope/assignable_scopes des deux rôles Azure personnalisés définis dans ce module (voir main.tf) — les garde visibles et assignables uniquement à l'intérieur de ce resource group, jamais au niveau subscription."
  type        = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\"."
  type        = string
}

variable "postgres_server_id" {
  description = "Resource ID of the PostgreSQL Flexible Server whose admin password gets rotated. Used to scope the Automation Account's role assignment to exactly this server rather than the whole resource group."
  type        = string
}

variable "postgres_server_name" {
  type = string
}

variable "postgres_server_fqdn" {
  description = "Needed to rebuild the connection string written back to Key Vault after each rotation."
  type        = string
}

variable "postgres_admin_username" {
  description = "Rotation only ever changes the password, never the username — this is here so the runbook can rebuild the full connection string, not to change it."
  type        = string
}

variable "postgres_database_name" {
  type = string
}

variable "key_vault_id" {
  description = "Scope for the Key Vault Secrets Officer role assignment. The runbook needs write access (not just read like the API's identity) because it overwrites the connection string secret after each rotation."
  type        = string
}

variable "key_vault_name" {
  type = string
}

variable "connection_string_secret_name" {
  description = "Key Vault secret this runbook writes arkcloudadmin's rotated connection string to. UNTIL Sprint 6's STRIDE cutover (task #69), ArkCloud.API read this exact secret directly — hence the historical default \"ConnectionStrings--DefaultConnection\" (Key Vault names can't contain \":\", .NET's config provider maps \"--\" to \":\"). Since the cutover, the running app connects as arkcloud_app instead and never reads this secret at all; environments/dev/main.tf now points this at a distinctly-named admin-only secret (\"Postgres--AdminConnection\") so this rotation can never silently clobber the app's real connection string again. What still needs this secret: any ops script authenticating as admin to manage arkcloud_app itself (bootstrap/rotation — see modules/azure/functions-experiment and its eventual Kudu-based replacement)."
  type        = string
  default     = "ConnectionStrings--DefaultConnection"
}

variable "rotation_interval_days" {
  description = "90 jours — la référence courante en entreprise : assez court pour borner la fenêtre d'exposition d'un identifiant fuité, assez espacé pour que chaque rotation (qui redémarre brièvement l'API) reste un non-événement."
  type        = number
  default     = 90

  # Même plafond appliqué que côté AWS (modules/aws/secret-rotation) — une politique de rotation
  # commune aux deux clouds n'a de sens que si les deux la font respecter, pas si l'une des deux
  # se contente d'une valeur par défaut modifiable sans contrainte.
  validation {
    condition     = var.rotation_interval_days > 0 && var.rotation_interval_days <= 90
    error_message = "L'intervalle de rotation doit être compris entre 1 et 90 jours (politique de sécurité du projet, identique côté AWS)."
  }
}

variable "rotation_start_time" {
  description = "RFC3339, must be at least 5 minutes in the future at apply time (Azure rejects schedules starting in the past). No longer needs to dodge peak hours for an App Service restart (removed at the Sprint 6 cutover — see connection_string_secret_name's description) — kept off-peak anyway since the PostgreSQL server itself briefly cycles through the password change."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
