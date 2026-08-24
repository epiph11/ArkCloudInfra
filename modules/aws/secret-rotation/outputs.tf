output "lambda_function_name" {
  description = "For tailing rotation logs: aws logs tail /aws/lambda/<this> --follow"
  value       = aws_lambda_function.rotation.function_name
}

output "rotation_interval_days" {
  value = var.rotation_interval_days
}
