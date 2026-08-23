variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\"."
  type        = string
}

variable "secret_arn" {
  description = "The Secrets Manager secret holding the .NET connection string the API reads (modules/aws/secrets' postgres secret). Rotation is attached to this secret, and the Lambda's IAM policy is scoped to exactly it."
  type        = string
}

variable "db_instance_identifier" {
  description = "RDS identifier (not ARN) — what modify-db-instance takes."
  type        = string
}

variable "db_instance_arn" {
  description = "For scoping the Lambda's rds:ModifyDBInstance permission to this one instance instead of \"*\"."
  type        = string
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_username" {
  description = "Username only — the Lambda rotates the password, never the username."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS injects secrets at task start, so running tasks keep the old password until redeployed. The Lambda forces a new deployment of the API service after promoting the new secret — same role the App Service restart plays on the Azure side."
  type        = string
}

variable "ecs_service_name" {
  description = "The API service specifically — Blazor doesn't read the DB secret."
  type        = string
}

variable "ecs_service_arn" {
  description = "For scoping the Lambda's ecs:UpdateService permission to this one service."
  type        = string
}

variable "vpc_subnet_ids" {
  description = "Private subnets with a route to RDS — the Lambda must run inside the VPC because the database has no public endpoint. Use the same ECS subnets the tasks run in (they already reach RDS and have NAT egress for the Secrets Manager/RDS/ECS API calls)."
  type        = list(string)
}

variable "database_security_group_id" {
  description = "sg-database — a rule is added to it allowing this Lambda's own security group in on the Postgres port, so the testSecret step can actually connect."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "rotation_interval_days" {
  description = "90 days, matching modules/azure/secret-rotation's schedule so both clouds follow one policy."
  type        = number
  default     = 90
}

variable "lambda_zip_path" {
  description = "Path to the built deployment package (see this module's lambda/README.md — the package has to be built once because it vendors psycopg2, which the Lambda Python runtime doesn't include). Defaults to the build output location the build script writes to."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
