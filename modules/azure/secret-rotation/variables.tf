variable "resource_group_name" {
  type = string
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
  description = "Key Vault secret holding the full Npgsql connection string the API reads. Key Vault names can't contain \":\", so .NET's config provider maps \"--\" to \":\" — hence the double dash."
  type        = string
  default     = "ConnectionStrings--DefaultConnection"
}

variable "app_service_id" {
  description = "App Service restarted after each rotation so it picks up the new connection string. Key Vault references are cached by the App Service platform, so without a restart the app keeps using the old (now invalid) password until its own refresh interval elapses."
  type        = string
}

variable "app_service_name" {
  type = string
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
  description = "RFC3339, must be at least 5 minutes in the future at apply time (Azure rejects schedules starting in the past). Pick an off-peak hour — the App Service restart that follows each rotation causes a brief interruption."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
