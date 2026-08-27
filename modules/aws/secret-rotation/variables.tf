variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\"."
  type        = string
}

variable "secret_arn" {
  description = "The Secrets Manager secret holding the .NET connection string the API reads (modules/aws/secrets' postgres secret). Rotation is attached to this secret, and the Lambda's IAM policy is scoped to exactly it."
  type        = string
}

variable "target_role" {
  description = "\"master\" (default) rotates RDS's own master user via the control-plane API — the original Sprint 6 behaviour. \"app\" rotates an arbitrary secondary Postgres role (e.g. arkcloud_app) via real SQL instead, because no management-plane API can touch a role that isn't the instance's designated master user. See lambda/rotate.py's TARGET_ROLE comment for the full reasoning."
  type        = string
  default     = "master"

  validation {
    condition     = contains(["master", "app"], var.target_role)
    error_message = "target_role must be \"master\" or \"app\"."
  }
}

variable "admin_secret_arn" {
  description = "target_role=\"app\" only: the master-user secret (modules/aws/secrets' postgres secret) this Lambda reads — never writes — to authenticate long enough to run CREATE ROLE / ALTER ROLE / GRANT against the target role. Required when target_role is \"app\"."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "target_role=\"app\" only: the username to connect as when managing the target role (the RDS master username)."
  type        = string
  default     = null
}

variable "db_instance_identifier" {
  description = "RDS identifier (not ARN) — what modify-db-instance takes. Required when target_role is \"master\"."
  type        = string
  default     = null
}

variable "db_instance_arn" {
  description = "For scoping the Lambda's rds:ModifyDBInstance permission to this one instance instead of \"*\". Required when target_role is \"master\"."
  type        = string
  default     = null
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
  description = "ECS injects secrets at task start, so running tasks keep the old password until redeployed. The Lambda forces a new deployment of the API service after promoting the new secret — same role the App Service restart plays on the Azure side. Leave null (default) if nothing reads this secret's rotated value yet — finishSecret skips the redeploy entirely rather than force-deploying a service for no reason."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "The API service specifically — Blazor doesn't read the DB secret. Leave null if nothing consumes this secret yet."
  type        = string
  default     = null
}

variable "ecs_service_arn" {
  description = "For scoping the Lambda's ecs:UpdateService permission to this one service. Leave null if nothing consumes this secret yet — the IAM statement is omitted entirely rather than granted against nothing."
  type        = string
  default     = null
}

variable "vpc_subnet_ids" {
  description = "Private subnets with a route to RDS — the Lambda must run inside the VPC because the database has no public endpoint. Use the same ECS subnets the tasks run in (they already reach RDS and have NAT egress for the Secrets Manager/RDS/ECS API calls)."
  type        = list(string)
}

variable "security_group_id" {
  description = "The rotation Lambda's security group, created in modules/aws/security (not here) so that its sg-database ingress can be an inline rule — mixing inline and standalone rules on the same security group makes the AWS provider delete the standalone one on every apply. See this module's main.tf header for the failure that caused."
  type        = string
}

variable "rotation_interval_days" {
  description = "90 jours, aligné sur modules/azure/secret-rotation pour que les deux clouds suivent une seule politique."
  type        = number
  default     = 90

  # Plafond réellement appliqué, pas seulement une valeur par défaut : sans cette validation,
  # n'importe quel appelant pourrait porter l'intervalle à 365 jours sans que rien ne s'y oppose,
  # et la « politique de rotation à 90 jours » ne serait qu'une convention orale.
  #
  # Le seuil de 90 n'est pas arbitraire : c'est celui retenu par les référentiels de sécurité
  # courants, et celui que le check Checkov CKV_AWS_304 vérifie (condition `days <= 90`, lue
  # dans son code source). Ce check échoue chez nous en faux positif — il ne sait pas résoudre
  # une variable à travers une frontière de module et retombe alors sur son cas d'échec. Cette
  # validation fait donc ce que le check voulait garantir, mais de façon réellement appliquée.
  validation {
    condition     = var.rotation_interval_days > 0 && var.rotation_interval_days <= 90
    error_message = "L'intervalle de rotation doit être compris entre 1 et 90 jours (politique de sécurité du projet, alignée sur Azure et sur CKV_AWS_304)."
  }
}

variable "lambda_zip_path" {
  description = "Path to the built deployment package (see this module's lambda/README.md — the package has to be built once because it vendors psycopg2, which the Lambda Python runtime doesn't include). Defaults to the build output location the build script writes to."
  type        = string
  default     = null
}

variable "alarm_sns_topic_arn" {
  description = "Existing alerts topic (modules/aws/monitoring) notified when a rotation fails. Optional — leave null to skip the alarm, but then a failed rotation is silent: Secrets Manager keeps the old working password, so nothing breaks visibly and the rotation quietly stops happening."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
