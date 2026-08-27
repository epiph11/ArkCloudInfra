variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "arkcloud_app_secret_arn" {
  description = "From modules/aws/secrets — the arkcloud_app (least-privilege, DML-only) role's connection string, granted to the execution role so ECS can inject it into a container as an env var before the process starts. NOT the admin secret: since the Sprint 6 STRIDE elevation-of-privilege cutover (task #69), the running application never reads the admin credential at all — only modules/aws/secret-rotation (a separate role, separate ARN) still touches it, to actually rotate it."
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
