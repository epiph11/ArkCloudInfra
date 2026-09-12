variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\"."
  type        = string
}

variable "arkcloud_app_secret_arn" {
  description = "modules/aws/secrets' arkcloud_app secret — this Lambda reads it (never writes) to connect as arkcloud_app, the same least-privilege role ArkCloud.API itself uses. No admin/master access is needed for this job."
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
  description = "The role this Lambda connects as — arkcloud_app by default (least privilege, same role ArkCloud.API itself uses). Not the RDS master user: this job never needs admin access."
  type        = string
  default     = "arkcloud_app"
}

variable "retention_years" {
  description = "Years of customer inactivity (measured from their most recent order, or from account creation if they have none) before anonymization. Decided with the user, docs/rgpd-classification-donnees.md §2 — not a value to change without the same conversation."
  type        = number
  default     = 3

  validation {
    condition     = var.retention_years > 0
    error_message = "retention_years must be a positive number of years."
  }
}

variable "schedule_expression" {
  description = "EventBridge schedule expression. Daily by default — the eligibility window is years, so this is far more frequent than strictly necessary, but the query is cheap and a daily cadence avoids writing any missed-run recovery logic. Mirrors the polling cadence of the Azure-side hosted service equivalent (CustomerRetentionPurgeHostedService)."
  type        = string
  default     = "rate(1 day)"
}

variable "vpc_subnet_ids" {
  description = "Same private subnets modules/aws/secret-rotation's Lambda runs in — this Lambda needs the exact same network path to RDS (no public endpoint)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Reuses modules/aws/security's secret_rotation_security_group_id rather than creating a new one — this Lambda needs the exact same sg-database ingress rule that Lambda already has, and creating a second SG would just duplicate the same access. See modules/aws/secret-rotation/main.tf's header comment for why that ingress rule has to stay a single inline block rather than being split across security groups."
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the built deployment package (see this module's lambda/build.sh). Defaults to the build output location the build script writes to."
  type        = string
  default     = null
}

variable "alarm_sns_topic_arn" {
  description = "Existing alerts topic (modules/aws/monitoring). Optional — leave null to skip the alarm, but then a failed purge run is silent (nothing breaks visibly, it just quietly doesn't happen)."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
