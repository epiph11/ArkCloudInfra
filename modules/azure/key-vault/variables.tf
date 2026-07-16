variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name" {
  description = "Globally unique Key Vault name (e.g. kv-arkcloud-dev)."
  type        = string
}

variable "tenant_id" {
  type = string
}

variable "sku_name" {
  type    = string
  default = "standard"
}

variable "soft_delete_retention_days" {
  type    = number
  default = 90
}

variable "purge_protection_enabled" {
  description = "Once true, cannot be disabled again for the life of the vault — deliberate, matches Step 16 hardening."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
