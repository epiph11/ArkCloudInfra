variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "From modules/aws/vpc — the ALB needs one subnet per AZ, public so it has a route to the Internet Gateway."
  type        = list(string)
}

variable "security_group_id" {
  description = "From modules/aws/security — sg-alb, 443/80 inbound from the Internet, egress to the ECS subnets only."
  type        = string
}

variable "container_port" {
  description = "Must match modules/aws/security's container_port and the ECS task definitions' container port — the target group forwards to this port on each Fargate task's ENI."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Same default as modules/azure/app-service, for parity between the two clouds' health checks."
  type        = string
  default     = "/health"
}

variable "tags" {
  type    = map(string)
  default = {}
}
