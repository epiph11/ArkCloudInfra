variable "name_prefix" {
  type = string
}

variable "finding_publishing_frequency" {
  description = "How often GuardDuty exports findings to EventBridge/the console. FIFTEEN_MINUTES (fastest) costs nothing extra over the other two options — this only affects export latency, not what GuardDuty analyzes or bills for — so there's no dev-tier reason to pick a slower one."
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.finding_publishing_frequency)
    error_message = "Must be one of FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS (AWS API's exact allowed values)."
  }
}

variable "min_severity_for_alert" {
  description = "GuardDuty severities run 1.0-8.9+ (Low <4, Medium 4-6.9, High/Critical >=7). 4.0 (Medium and up) is the floor here on purpose — Low findings are mostly opportunistic internet noise (port scans against the ALB, routine recon) that would otherwise flood the same inbox as real CloudWatch alarms and teach the team to ignore it."
  type        = number
  default     = 4.0
}

variable "alarm_sns_topic_arn" {
  description = "modules/aws/monitoring's existing alerts topic — findings land in the same inbox as CloudWatch alarms rather than a separate channel nobody watches. This module only reads the ARN to use as an EventBridge target; the SNS resource policy statement granting EventBridge permission to publish here is owned by the root module (environments/dev/main.tf), not by this module — see the comment there for why two modules must never each attach their own policy to the same topic."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
