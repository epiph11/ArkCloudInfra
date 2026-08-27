# Shared cluster + IAM for both services (api, web) — mirrors how modules/azure/key-vault and
# modules/azure/monitoring are single shared modules that both app-service instances reference,
# rather than duplicating a cluster per app. modules/aws/ecs-service (instantiated twice at
# root, once per app) is the AWS counterpart to modules/azure/app-service.

resource "aws_ecs_cluster" "this" {
  name = "arkcloud-${var.name_prefix}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# --- Execution role: ECS-agent-level permissions (pull the image, write logs, fetch secrets
# to inject as env vars before the container process starts). No direct Azure equivalent —
# App Service's platform handles image pull/logging itself without a separate identity for it.
resource "aws_iam_role" "execution" {
  name = "ecs-execution-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Read access to the two Secrets Manager containers created in modules/aws/secrets — this is
# what lets the "secrets" block in each task definition (modules/aws/ecs-service) resolve a
# secret ARN into an env var value at container startup.
#
# arkcloud_app's secret, not the admin one: the execution role only needs to read whatever gets
# injected as ConnectionStrings__DefaultConnection, and since the Sprint 6 cutover that's
# arkcloud_app's connection string (DML-only). Granting read on the admin secret here too would
# undermine the least-privilege point of that cutover — nothing running under this role has any
# remaining reason to ever see arkcloudadmin's credential.
resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.arkcloud_app_secret_arn, var.jwt_secret_arn]
    }]
  })
}

# --- Task role: what the RUNNING APPLICATION CODE itself can call via the AWS SDK — the real
# parallel to Azure's Managed Identity + Key Vault Secrets User role assignment
# (modules/azure/identity). Empty for now because nothing in ArkCloud.API calls AWS APIs
# directly yet (secrets are injected as plain env vars via the execution role above instead,
# so no app code change was needed for Sprint 5). Kept as its own role, not skipped, so a
# future feature that needs real AWS SDK access from inside the app has somewhere to attach a
# policy without redefining the role or its trust relationship.
resource "aws_iam_role" "task" {
  name = "ecs-task-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}
