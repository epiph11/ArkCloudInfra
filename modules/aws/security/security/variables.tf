variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "container_port" {
  description = "Port both ArkCloud.API and ArkCloud.Blazor listen on inside their containers — same port for both is fine, they're in different target groups/security groups regardless."
  type        = number
  default     = 8080
}

variable "tags" {
  type    = map(string)
  default = {}
}
