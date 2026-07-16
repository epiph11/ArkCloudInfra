variable "scope" {
  description = "Resource id the role is granted on — typically the Key Vault id from the key-vault module."
  type        = string
}

variable "principal_id" {
  description = "Object id of the identity being granted the role — e.g. the App Service's system-assigned identity principal_id output."
  type        = string
}

variable "role_definition_name" {
  description = "Built-in Azure role name. Default matches Step 7.6: the App Service reads secrets, never writes/manages them."
  type        = string
  default     = "Key Vault Secrets User"
}
