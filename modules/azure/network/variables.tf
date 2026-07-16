variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "address_space" {
  description = "VNet address space, e.g. [\"10.10.0.0/16\"]."
  type        = list(string)
}

variable "api_subnet_prefix" {
  description = "VNet integration subnet (outbound only) for ArkCloud.API's App Service Plan — the only one allowed to reach PostgreSQL."
  type        = string
}

variable "web_subnet_prefix" {
  description = "VNet integration subnet (outbound only) for ArkCloud.Blazor's App Service Plan. Separate from api_subnet_prefix because Azure ties one VNet-integration subnet to one App Service Plan — API and Blazor are on different Plans, so they can't share a subnet."
  type        = string
}

variable "database_subnet_prefix" {
  description = "Delegated subnet for PostgreSQL Flexible Server (private access)."
  type        = string
}

variable "private_endpoint_subnet_prefix" {
  description = "Reserved for private endpoints (Key Vault, storage, etc.) — not all provisioned yet in Sprint 4."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
