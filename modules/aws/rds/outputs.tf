output "db_instance_id" {
  value = aws_db_instance.this.id
}

output "endpoint" {
  description = "host:port — same shape as Azure's fqdn output, but includes the port since RDS's endpoint attribute already bundles it."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only, no port — for connection strings that need it separately."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}
