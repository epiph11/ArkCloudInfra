output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_api_security_group_id" {
  value = aws_security_group.ecs_api.id
}

output "ecs_web_security_group_id" {
  value = aws_security_group.ecs_web.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}
