variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "postgres_secret_arn" {
  description = "From modules/aws/secrets — granted to the execution role so ECS can inject it into a container as an env var before the process starts."
  type        = string
}

variable "jwt_secret_arn" {
  description = "From modules/aws/secrets — same mechanism as postgres_secret_arn."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
