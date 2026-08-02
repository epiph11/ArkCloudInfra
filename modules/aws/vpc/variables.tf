variable "name_prefix" {
  description = "Prefixed onto every resource name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Exactly two AZs — dev doesn't need three, but one alone defeats the point of public/private subnet pairs across zones."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "ecs_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "database_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
