variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
