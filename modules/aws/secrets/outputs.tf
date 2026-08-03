output "postgres_secret_arn" {
  value = aws_secretsmanager_secret.postgres.arn
}

output "postgres_secret_name" {
  value = aws_secretsmanager_secret.postgres.name
}

output "jwt_secret_arn" {
  value = aws_secretsmanager_secret.jwt.arn
}

output "jwt_secret_name" {
  value = aws_secretsmanager_secret.jwt.name
}
