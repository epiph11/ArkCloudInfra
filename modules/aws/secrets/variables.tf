variable "name_prefix" {
  description = "Prefixed onto every secret name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "recovery_window_in_days" {
  description = "7 for dev — fast, clean teardown (secret names free up quickly instead of staying reserved). Use 30 for staging/prod, where an accidental deletion should be recoverable."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
