# ---------------------------------------------------------------------------
# Automatic PostgreSQL password rotation — AWS side (Sprint 6). Counterpart to
# modules/azure/secret-rotation, same 90-day policy, same three effective steps (rotate the
# password, rewrite the connection string, roll the app so it picks it up).
#
# Why a custom Lambda instead of AWS's own rotation template: AWS's
# SecretsManagerRDSPostgreSQLRotationSingleUser Lambda requires the secret to be structured JSON
# ({"engine","host","username","password","dbname","port"}). This project's secret holds a plain
# .NET connection string, because ArkCloud.API reads it wholesale via
# GetConnectionString("DefaultConnection") and the ECS task definition maps the secret straight
# onto ConnectionStrings__DefaultConnection (environments/dev/main.tf). Reformatting the secret
# to AWS's shape would mean changing the application AND diverging from Azure, which reads a
# connection string out of Key Vault the same way. See lambda/rotate.py for the rotation logic.
#
# Build step required: the deployment package vendors psycopg2 (not in the Lambda Python
# runtime) — see lambda/README.md. Deliberately not built by Terraform via local-exec: that
# makes `terraform plan` depend on pip/docker being present on whatever machine runs it,
# including CI, which is a worse failure mode than one documented build command.
# ---------------------------------------------------------------------------

locals {
  lambda_zip = coalesce(var.lambda_zip_path, "${path.module}/lambda/build/rotate.zip")

  # Master keeps its original, unsuffixed name — this module already existed with target_role
  # defaulting to "master" before app-role support was added, and renaming it would force
  # Terraform to destroy/recreate the already-working, already-scheduled master rotation Lambda
  # for no functional reason. Only the new app-role instantiation gets a suffix.
  resource_name = var.target_role == "master" ? "secret-rotation-${var.name_prefix}" : "secret-rotation-${var.name_prefix}-${var.target_role}"

  # Same backward-compatibility concern, separately, for the CloudWatch alarm: its original name
  # ("${name_prefix}-secret-rotation-errors") uses a different word order than resource_name
  # above. Reusing resource_name here would rename -- and therefore replace -- the master alarm
  # for no functional reason (confirmed by a real `terraform plan` showing exactly that
  # `-/+ must be replaced` before this local existed). Master keeps its exact original name; only
  # app-role gets the newer, more descriptive pattern.
  alarm_name = var.target_role == "master" ? "${var.name_prefix}-secret-rotation-errors" : "${local.resource_name}-errors"
}

# This module deliberately does NOT create the Lambda's security group or its sg-database
# ingress rule — both live in modules/aws/security instead, and the SG id is passed in.
#
# The reason is a real failure, not tidiness: sg-database uses inline `ingress` blocks, and the
# AWS provider treats inline rules as the complete authoritative set for a security group. A
# standalone aws_vpc_security_group_ingress_rule pointing at the same SG gets deleted on every
# apply, then recreated on the next refresh — and while it's missing, this Lambda has no route
# to RDS. That flip-flop is what produced the "timeout expired" failure seen during rotation
# testing (a missing SG rule times out rather than being refused, so it looks like slowness).
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation" {
  name               = local.resource_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = var.tags
}

# Managed policy for the ENI plumbing a VPC-attached Lambda needs (CreateNetworkInterface etc.).
# These are inherently account-wide actions — AWS's own managed policy is the standard answer,
# and hand-rolling an equivalent wouldn't make it narrower.
resource "aws_iam_role_policy_attachment" "rotation_vpc" {
  role       = aws_iam_role.rotation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Everything else is scoped to the exact resources involved — same least-privilege posture as
# the ECS task role (modules/aws/ecs) and the Azure runbook's per-resource role assignments.
data "aws_iam_policy_document" "rotation" {
  statement {
    sid = "RotateThisSecretOnly"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [var.secret_arn]
  }

  statement {
    sid       = "GenerateRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"] # No resource to scope to — this call creates nothing, it just returns a string.
  }

  # target_role="master" only — the RDS control-plane API used to rotate the one designated
  # master account. Omitted entirely for target_role="app" rather than granted against nothing:
  # that path never calls rds:ModifyDBInstance (see lambda/rotate.py's TARGET_ROLE branching),
  # and a role that isn't the master account can't be reached through this API regardless.
  dynamic "statement" {
    for_each = var.target_role == "master" ? [1] : []
    content {
      sid = "ModifyThisDatabaseOnly"
      actions = [
        "rds:ModifyDBInstance",
        # Describe is needed by setSecret's wait loop — ModifyDBInstance is asynchronous, so the
        # function polls until RDS reports the new password actually applied before letting
        # testSecret run against it.
        "rds:DescribeDBInstances",
      ]
      resources = [var.db_instance_arn]
    }
  }

  # Omitted when ecs_service_arn is null (target_role="app" today, until roadmap step 4 wires
  # ArkCloud.API onto arkcloud_app) — finishSecret already skips the redeploy call itself when
  # ECS_SERVICE isn't set; not granting the permission either is the same "don't hold access you
  # don't use yet" posture the rest of this project's IAM follows.
  dynamic "statement" {
    for_each = var.ecs_service_arn != null ? [1] : []
    content {
      sid       = "RedeployApiServiceOnly"
      actions   = ["ecs:UpdateService"]
      resources = [var.ecs_service_arn]
    }
  }

  # target_role="app" only — read-only access to the master secret, purely to authenticate long
  # enough to run CREATE ROLE / ALTER ROLE / GRANT against the target role. No write action is
  # ever granted here: this Lambda must never be able to change the admin account's own password.
  dynamic "statement" {
    for_each = var.target_role == "app" ? [1] : []
    content {
      sid       = "ReadAdminSecretForRoleManagementOnly"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.admin_secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotation"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

resource "aws_cloudwatch_log_group" "rotation" {
  name              = "/aws/lambda/${local.resource_name}"
  retention_in_days = 30 # Same window as the other log groups in this project.

  tags = var.tags
}

resource "aws_lambda_function" "rotation" {
  function_name = local.resource_name
  role          = aws_iam_role.rotation.arn
  handler       = "rotate.lambda_handler"
  runtime       = "python3.12"
  filename      = local.lambda_zip
  # Without this, updating rotate.py wouldn't redeploy the function — Terraform only sees the
  # filename, not its contents.
  source_code_hash = filebase64sha256(local.lambda_zip)

  # Sized against the worst case of the two waits in rotate.py, not the typical case: setSecret
  # polls up to 5 min for RDS to apply the password, and testSecret retries the connection for
  # up to ~90s after that. 600s leaves real margin; each Lambda step is invoked separately by
  # Secrets Manager, so this ceiling applies per step rather than to the whole rotation.
  # (The default 3s, and the 60s this started at, were both far too short — the 60s would have
  # killed setSecret mid-wait.)
  timeout = 600

  # No reserved_concurrent_executions (Checkov CKV_AWS_115, skipped in terraform-ci.yml) —
  # not a choice, an account limit. Setting it to even 2 fails at apply time:
  #   InvalidParameterValueException: Specified ReservedConcurrentExecutions for function
  #   decreases account's UnreservedConcurrentExecution below its minimum value of [10].
  # This account's total Lambda concurrency quota is at the default floor for a new account, and
  # AWS refuses any reservation that would drop the unreserved pool under 10. Revisit once a
  # concurrency quota increase is requested — the check is reasonable, it just isn't satisfiable
  # here today.
  # X-Ray (Checkov CKV_AWS_50) — genuinely useful here rather than box-ticking: this function
  # spans RDS, Secrets Manager, ECS and a database connection, and the two bugs found during
  # its first runs were both about *when* things happened relative to each other. Traces make
  # that visible instead of inferred from log timestamps.
  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = merge(
      {
        TARGET_ROLE = var.target_role
        DB_HOST     = var.db_host
        DB_PORT     = tostring(var.db_port)
        DB_NAME     = var.db_name
        DB_USERNAME = var.db_username
      },
      # master-only — the RDS instance identifier and the ECS service to redeploy afterwards.
      var.target_role == "master" ? {
        DB_INSTANCE_IDENTIFIER = var.db_instance_identifier
      } : {},
      # Set for either role, as long as a consumer is configured (null → key omitted, and
      # finishSecret's `if not ECS_SERVICE` treats an unset env var the same as an empty one).
      var.ecs_cluster_name != null ? { ECS_CLUSTER = var.ecs_cluster_name } : {},
      var.ecs_service_name != null ? { ECS_SERVICE = var.ecs_service_name } : {},
      # app-only — credentials to connect as, to manage a role that isn't the connecting user.
      var.target_role == "app" ? {
        ADMIN_SECRET_ARN = var.admin_secret_arn
        ADMIN_USERNAME   = var.admin_username
      } : {},
    )
  }

  depends_on = [
    aws_iam_role_policy_attachment.rotation_vpc,
    aws_cloudwatch_log_group.rotation,
  ]

  tags = var.tags
}

# Secrets Manager invokes the function itself — without this it gets AccessDeniedException and
# rotation silently never runs.
resource "aws_lambda_permission" "secretsmanager" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = var.secret_arn
}

# A failed rotation is silent by default: Secrets Manager retries, gives up, and leaves the
# secret on its old (still valid) version — the app keeps working, so nothing surfaces until
# someone happens to look. This alarm is what makes the failure visible.
#
# Deliberately chosen over the Lambda DLQ that Checkov asks for (CKV_AWS_116, skipped in
# terraform-ci.yml): Secrets Manager does invoke this function asynchronously, so a DLQ is
# technically applicable — but it would only accumulate event payloads nobody reads. Knowing
# rotation broke is the actual requirement, and that's an alarm, not a queue.
resource "aws_cloudwatch_metric_alarm" "rotation_errors" {
  count = var.alarm_sns_topic_arn != null ? 1 : 0

  alarm_name        = local.alarm_name
  alarm_description = "The Postgres password rotation Lambda failed (target_role=${var.target_role}). The secret stays on its previous version (the app keeps working), but the password has NOT rotated - check /aws/lambda/${local.resource_name}."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.rotation.function_name
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # Rotation runs every 90 days, so the metric is absent almost all the time — treating missing
  # data as "not breaching" avoids an alarm that sits in INSUFFICIENT_DATA permanently.
  treat_missing_data = "notBreaching"

  alarm_actions = [var.alarm_sns_topic_arn]
  ok_actions    = [var.alarm_sns_topic_arn]

  tags = var.tags
}

resource "aws_secretsmanager_secret_rotation" "postgres" {
  secret_id           = var.secret_arn
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.rotation_interval_days
  }

  # Attaching rotation triggers an immediate first rotation. That's the desired behaviour (it
  # proves the whole path works rather than waiting 90 days to find out it doesn't) — but it
  # does mean the API briefly redeploys right after the first apply of this module.
  depends_on = [aws_lambda_permission.secretsmanager]
}
