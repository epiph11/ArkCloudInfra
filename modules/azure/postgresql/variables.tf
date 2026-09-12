variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "server_name" {
  description = "Globally unique PostgreSQL Flexible Server name (e.g. psql-arkcloud-dev)."
  type        = string
}

variable "postgresql_version" {
  type    = string
  default = "16"
}

variable "sku_name" {
  description = "e.g. B_Standard_B1ms (dev, burstable) or GP_Standard_D2s_v3 (staging/prod, general purpose)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "storage_auto_grow_enabled" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "geo_redundant_backup_enabled" {
  description = "Zone/geo-redundant backups — enable for prod only, adds cost."
  type        = bool
  default     = false
}

variable "administrator_login" {
  type      = string
  sensitive = true
}

variable "administrator_password" {
  description = "Never set as a literal in .tfvars committed to git — pass via TF_VAR_administrator_password env var or CI secret."
  type        = string
  sensitive   = true
}

variable "delegated_subnet_id" {
  description = "Database subnet id from the network module (must be delegated to Microsoft.DBforPostgreSQL/flexibleServers)."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet id, needed to link the private DNS zone used for private access."
  type        = string
}

variable "database_name" {
  type    = string
  default = "arkcloud"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- Passwordless Azure (Sprint 6 clôture, ADR-0011) ---

variable "entra_admin_tenant_id" {
  description = "Tenant Entra ID sous lequel l'authentification AAD du serveur est activée — data.azurerm_client_config.current.tenant_id côté appelant."
  type        = string
}

variable "entra_admin_object_id" {
  description = "Object ID du principal Entra ID désigné administrateur du serveur (peut créer d'autres rôles AAD via pgaadauth_create_principal). Volontairement l'identité qui applique ce Terraform, pas l'identité managée de l'App Service — voir le commentaire sur azurerm_postgresql_flexible_server_active_directory_administrator.this dans main.tf."
  type        = string
}

variable "entra_admin_principal_name" {
  description = "Nom lisible du même principal (UPN pour un utilisateur, nom d'affichage pour un service principal) — affiché dans le portail Azure, pas utilisé pour l'authentification elle-même."
  type        = string
}

variable "entra_admin_principal_type" {
  description = "\"User\", \"ServicePrincipal\" ou \"Group\" — doit correspondre au type réel du principal ci-dessus."
  type        = string
  default     = "User"
}
