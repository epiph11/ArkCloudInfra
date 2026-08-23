output "service_name" {
  value = aws_ecs_service.this.name
}

output "service_arn" {
  description = "For scoping an ecs:UpdateService permission to this one service — used by modules/aws/secret-rotation."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
