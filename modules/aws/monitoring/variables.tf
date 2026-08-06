variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "api_service_name" {
  type = string
}

variable "web_service_name" {
  type = string
}

variable "api_log_group_name" {
  type = string
}

variable "web_log_group_name" {
  type = string
}

variable "alb_arn_suffix" {
  description = "CloudWatch's expected LoadBalancer dimension value, e.g. \"app/alb-arkcloud-dev/1234567890abcdef\" — NOT the full ARN, and without the \"loadbalancer/\" prefix that the real ARN has (AWS quirk: TargetGroup dimensions keep their \"targetgroup/\" prefix, LoadBalancer dimensions drop \"loadbalancer/\")."
  type        = string
}

variable "api_target_group_arn_suffix" {
  description = "CloudWatch's expected TargetGroup dimension value, e.g. \"targetgroup/tg-api-arkcloud-dev/1234567890abcdef\"."
  type        = string
}

variable "web_target_group_arn_suffix" {
  type = string
}

variable "rds_instance_id" {
  type = string
}

variable "alarm_email" {
  description = "Optional — subscribes this address to the alerts SNS topic (requires clicking a confirmation link AWS emails on apply). Leave null to create the topic without a subscriber; alarms will still fire and be visible in the console/CLI, just without email delivery."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
