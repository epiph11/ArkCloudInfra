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

# --- Sprint 6, passwordless AWS (ADR-0011, scope AWS) ---

variable "rds_resource_id" {
  description = "module.aws_rds.resource_id (DbiResourceId) — used to scope the rds-db:connect policy on the task role to exactly this instance/user, same ARN shape RDS IAM auth requires."
  type        = string
}

variable "rds_username" {
  description = "The Postgres role the task role is allowed to connect as via IAM auth — arkcloud_app, not the admin/master user (ADR-0011 explicitly keeps the admin role on password auth)."
  type        = string
  default     = "arkcloud_app"
}

variable "aws_region" {
  description = "For the rds-db:connect ARN (arn:aws:rds-db:<region>:<account>:dbuser:...) — no default, must match the region RDS was actually created in."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
