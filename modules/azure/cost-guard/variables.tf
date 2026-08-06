variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  description = "Full ARM resource ID of the resource group (module.resource_group.id) — the budget is scoped here, not at the subscription level, so rg-terraform-state's negligible cost doesn't count toward the threshold."
  type        = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  description = "e.g. \"arkcloud-dev\" — used to name the Automation Account, runbook webhook, action groups and budget."
  type        = string
}

variable "postgres_server_id" {
  description = "Resource ID of the PostgreSQL Flexible Server the runbook stops. The Contributor role assignment is scoped to exactly this resource, not the resource group — least-privilege, same pattern as the AWS IAM roles elsewhere in this project."
  type        = string
}

variable "postgres_server_name" {
  type = string
}

variable "budget_amount_eur" {
  description = "Monthly budget threshold in EUR, scoped to this resource group. At 100% actual spend, the automation runbook stops the PostgreSQL Flexible Server automatically. At 80%, only a warning email fires (if alert_email is set) — a chance to intervene manually before the automatic stop."
  type        = number
  default     = 7
}

variable "alert_email" {
  description = "Optional — receives the 80% warning and is cc'd on the 100%/action-triggered notification. Left unset by default so it stays out of version control; set via TF_VAR_alert_email or terraform.tfvars."
  type        = string
  default     = null
}

variable "budget_start_date" {
  description = "First day of a month, RFC3339 (e.g. \"2026-08-01T00:00:00Z\"). Azure requires this to align to the Monthly time_grain and is effectively immutable after creation — pick the first day of the month you apply this in."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
