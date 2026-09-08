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

output "master_username" {
  description = "Username only — never the password. Needed by modules/aws/secret-rotation to rebuild the connection string after rotating."
  value       = aws_db_instance.this.username
}

output "db_instance_identifier" {
  description = "The RDS identifier (psql-<prefix>), not the ARN — what modify-db-instance takes as --db-instance-identifier."
  value       = aws_db_instance.this.identifier
}

output "arn" {
  description = "For scoping the rotation Lambda's IAM policy to exactly this instance."
  value       = aws_db_instance.this.arn
}

output "resource_id" {
  description = "DbiResourceId — the identifier IAM DB auth policies need (arn:aws:rds-db:region:account:dbuser:{resource_id}/{db_user}), NOT the instance identifier or ARN used elsewhere in this module. Sprint 6, passwordless AWS (ADR-0011)."
  value       = aws_db_instance.this.resource_id
}
