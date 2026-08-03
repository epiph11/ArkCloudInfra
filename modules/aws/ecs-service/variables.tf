variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "service_name" {
  description = "\"api\" or \"web\" — becomes the container name, part of every resource name, and the CloudWatch log stream prefix."
  type        = string
}

variable "cluster_id" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "subnet_ids" {
  description = "From modules/aws/vpc — the private ECS subnets (no direct route to the Internet, outbound only via NAT)."
  type        = list(string)
}

variable "security_group_id" {
  description = "sg-ecs-api or sg-ecs-web from modules/aws/security, matching service_name."
  type        = string
}

variable "target_group_arn" {
  description = "From modules/aws/alb — tg-api or tg-web, matching service_name."
  type        = string
}

variable "container_image" {
  description = "Repository URL without the tag, e.g. module.aws_ecr.api_repository_url."
  type        = string
}

variable "container_image_tag" {
  type    = string
  default = "dev"
}

variable "container_port" {
  description = "Must match the target group's port and modules/aws/security's container_port."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "256 = 0.25 vCPU, the cheapest Fargate size — dev tier, same reasoning as db.t3.micro/B1. Fargate requires cpu/memory to be one of a fixed set of paired values."
  type        = number
  default     = 256
}

variable "memory" {
  description = "512 MiB — the minimum memory paired with cpu = 256 in Fargate's fixed size table."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "1 for dev — no redundancy, matches App Service's B1 tier having no auto-scale either."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "30 for dev — shorter than a compliance-driven retention policy would require, revisit for staging/prod."
  type        = number
  default     = 30
}

variable "environment" {
  description = "Plain (non-secret) environment variables — .NET config keys using \"__\" as the nested-section separator, e.g. {\"ASPNETCORE_ENVIRONMENT\" = \"Production\"}."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env var name -> Secrets Manager secret ARN. Injected by the ECS agent (via the execution role) before the container starts, same shape as environment but resolved from Secrets Manager instead of a literal value."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
