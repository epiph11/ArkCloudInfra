# AWS's default for the rds.force_ssl parameter is 0 (off) — unlike Azure Flexible Server,
# which enforces TLS out of the box (see modules/azure/postgresql's comment on
# require_secure_transport). A dedicated parameter group is the only way to flip it, since
# it isn't an attribute on aws_db_instance itself.
#
# Also carries query-level audit logging: log_statement="ddl" logs schema changes
# (CREATE/ALTER/DROP — security-relevant, low volume) without logging every SELECT/INSERT,
# which would be both noisy and a real risk of leaking customer data or query params into
# CloudWatch Logs. log_min_duration_statement=1000 separately logs any query slower than 1s
# regardless of type — a performance signal, not an audit one. Together these are the AWS
# counterpart to PostgreSQL Flexible Server's own log settings on the Azure side, and both
# feed the "postgresql" CloudWatch log export already enabled on aws_db_instance.this below.
resource "aws_db_parameter_group" "postgres16" {
  name_prefix = "pg16-${var.name_prefix}-"
  family      = "postgres16"
  description = "Forces SSL (rds.force_ssl=1); log_statement=ddl + log_min_duration_statement=1000 for query/audit logging."

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_statement"
    value        = "ddl"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = var.tags

  # Parameter group can't be deleted while the DB instance is using it — create the
  # replacement before destroying the old one on any future change to this resource.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = "psql-${var.name_prefix}"
  engine         = "postgres"
  engine_version = var.engine_version

  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  max_allocated_storage  = var.max_allocated_storage
  storage_type            = "gp3"
  storage_encrypted       = true # KMS-encrypted at rest using the AWS-managed aws/rds key — no dedicated CMK for dev, same "managed key is enough" call as not standing up a separate Key Vault HSM tier on the Azure side.

  db_name  = var.database_name
  username = var.master_username
  password = var.master_password
  port     = 5432

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.postgres16.name

  publicly_accessible = false
  multi_az            = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window            = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "psql-${var.name_prefix}-final"

  deletion_protection = var.deletion_protection

  # Free (no extra infrastructure needed) — lets IAM roles (the ECS task role, once
  # modules/aws/ecs exists) authenticate to Postgres without a long-lived DB password,
  # same direction as Azure's Managed Identity pattern for Key Vault access.
  iam_database_authentication_enabled = true

  performance_insights_enabled = var.performance_insights_enabled

  # Routes postgresql.log + upgrade logs to CloudWatch Logs (auto-creates the log group) —
  # the AWS counterpart to the diag-psql-arkcloud-${var.environment} diagnostic setting
  # already wired on the Azure side. Full CloudWatch dashboards/alarms are Step 15 (Sprint 5),
  # this just makes sure the data exists to query once that lands.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = merge(var.tags, { Name = "psql-${var.name_prefix}" })

  lifecycle {
    # Same reasoning as Azure's administrator_password: password rotation should be a
    # deliberate, separate change — not an incidental side effect of an unrelated apply
    # picking up a stale var value.
    ignore_changes = [password]
  }
}
