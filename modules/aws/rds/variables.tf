variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "engine_version" {
  description = "Major version only (e.g. \"16\") lets AWS pick the latest supported minor automatically, same intent as Azure's postgresql_version = \"16\"."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "db.t3.micro (burstable, cheapest) for dev — mirrors postgres_sku's B_Standard_B1ms on the Azure side. Use a larger, non-burstable class for staging/prod."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling — AWS equivalent of Azure's storage_auto_grow_enabled."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "false for dev (single AZ, cheaper) — mirrors geo_redundant_backup_enabled being false-by-default on the Azure side. Override true for staging/prod."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "1 for dev — this AWS account is on the Free Tier plan, which rejects CreateDBInstance with FreeTierRestrictionError above some undocumented retention cap (7 was too high; AWS doesn't publish the exact allowed value). 1 still keeps automated backups on rather than disabling them (0 would). Override higher for staging/prod, where the account presumably isn't Free Tier-restricted."
  type        = number
  default     = 1
}

variable "database_name" {
  type    = string
  default = "arkcloud"
}

variable "master_username" {
  type      = string
  sensitive = true
  default   = "arkcloudadmin"
}

variable "master_password" {
  description = "Never set as a literal in .tfvars committed to git — pass via TF_VAR_aws_postgres_admin_password env var or a CI secret."
  type        = string
  sensitive   = true
}

variable "db_subnet_group_name" {
  description = "From modules/aws/vpc — the two database (private, no NAT route) subnets."
  type        = string
}

variable "security_group_id" {
  description = "From modules/aws/security — sg-database, ingress from sg-ecs-api only."
  type        = string
}

variable "skip_final_snapshot" {
  description = "true for dev (fast, clean teardown). Set false + rely on final_snapshot_identifier for staging/prod, where losing the last snapshot on destroy would be a real problem."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "false for dev — the whole point of this environment is to be destroyable on demand. true for staging/prod."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "db.t3.micro doesn't meaningfully support Performance Insights (too little memory to be useful) — left off for dev, revisit with a larger instance class in staging/prod."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
