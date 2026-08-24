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

output "secret_rotation_security_group_id" {
  description = "Created here rather than in modules/aws/secret-rotation so its sg-database ingress can be inline — see that resource's comment for why mixing inline and standalone rules breaks."
  value       = aws_security_group.secret_rotation.id
}
