variable "name" {
  description = "Resource Group name (e.g. rg-arkcloud-dev)."
  type        = string
}

variable "location" {
  description = "Azure region (e.g. westeurope)."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Resource Group and inherited by convention by resources inside it."
  type        = map(string)
  default     = {}
}
