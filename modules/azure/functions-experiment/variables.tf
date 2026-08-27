variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\" — matches every other module's naming convention."
  type        = string
}

variable "subnet_id" {
  description = "TEMPORARY subnet dedicated to this experiment (modules/azure/network's functions_subnet_id output) — delegated to Microsoft.App/environments, cannot be shared with snet-api/snet-web/snet-database."
  type        = string
}

variable "postgres_host" {
  description = "PostgreSQL Flexible Server FQDN (modules/azure/postgresql's fqdn output)."
  type        = string
}

variable "postgres_database_name" {
  type = string
}

variable "postgres_admin_username" {
  description = "Read-only here — used to log in as admin (to run CREATE ROLE/GRANT) and to name the owner in ALTER DEFAULT PRIVILEGES. The admin password itself is never a Terraform value; the function reads it from Key Vault at runtime."
  type        = string
}

variable "key_vault_id" {
  description = "Scope for the Key Vault Secrets Officer role assignment (RBAC authorization model — see modules/azure/key-vault, no per-secret scoping available)."
  type        = string
}

variable "key_vault_uri" {
  type = string
}

variable "admin_connection_string_secret_name" {
  description = "Name of the existing Key Vault secret holding arkcloudadmin's live connection string — \"ConnectionStrings--DefaultConnection\" today. The function only ever reads this one; it never writes it."
  type        = string
  default     = "ConnectionStrings--DefaultConnection"
}

variable "app_role_secret_name" {
  description = "Name of the (new) Key Vault secret the function writes arkcloud_app's connection string to. Not consumed by ArkCloud.API yet — that cutover is a separate, later step (roadmap step 4)."
  type        = string
  default     = "ArkCloudAppRole--Password"
}

variable "application_insights_connection_string" {
  description = "modules/azure/monitoring's connection_string output (the project's existing, shared App Insights instance — no new one created for this experiment). Needed here because az webapp log tail / az webapp log config both came back non-functional against this Flex Consumption app (see main.tf's header for the running list of Flex Consumption tooling gaps found during this experiment); App Insights is the path Microsoft actually documents for this plan."
  type        = string
  sensitive   = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
