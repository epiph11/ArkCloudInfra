# ---------------------------------------------------------------------------
# RGPD automated retention purge — AWS side (Sprint 6, ADR-0012).
#
# Counterpart to ArkCloud.API's CustomerRetentionPurgeHostedService, which plays the same role
# on Azure. The mechanism differs deliberately between the two clouds: Azure has to run this
# in-process (an Azure Automation Runbook has no network path to the private VNet Postgres lives
# in — the same constraint ADR-0010 already documents for a different job), while AWS can run a
# small standalone Lambda inside the VPC, reusing the exact same network path
# modules/aws/secret-rotation's rotation Lambda already has proven. See lambda/purge.py's module
# docstring for the full reasoning, including why this is a new Lambda rather than a mode added
# to secret-rotation's existing one (that one is driven by Secrets Manager's rotation state
# machine — there is no secret being rotated here, so it doesn't fit).
#
# Build step required before first apply: lambda/build.sh vendors psycopg2 the same way
# modules/aws/secret-rotation does — see that module's main.tf header for why this isn't done via
# Terraform local-exec.
# ---------------------------------------------------------------------------

locals {
  lambda_zip    = coalesce(var.lambda_zip_path, "${path.module}/lambda/build/purge.zip")
  resource_name = "gdpr-purge-${var.name_prefix}"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "purge" {
  name               = local.resource_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = var.tags
}

# AWSLambdaVPCAccessExecutionRole covers both the ENI plumbing a VPC-attached Lambda needs AND
# basic CloudWatch Logs permissions — same single attachment modules/aws/secret-rotation uses,
# no separate basic-execution policy needed.
resource "aws_iam_role_policy_attachment" "purge_vpc" {
  role       = aws_iam_role.purge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Read-only, scoped to exactly the one secret this Lambda needs to authenticate as arkcloud_app —
# no write action, no access to the admin/master secret at all (unlike secret-rotation's app-role
# Lambda, this one never needs to manage the role itself, only connect as it).
data "aws_iam_policy_document" "purge" {
  statement {
    sid       = "ReadArkCloudAppSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.arkcloud_app_secret_arn]
  }
}

resource "aws_iam_role_policy" "purge" {
  name   = "gdpr-purge"
  role   = aws_iam_role.purge.id
  policy = data.aws_iam_policy_document.purge.json
}

resource "aws_cloudwatch_log_group" "purge" {
  name              = "/aws/lambda/${local.resource_name}"
  retention_in_days = 30 # Same window as every other log group in this project.

  tags = var.tags
}

resource "aws_lambda_function" "purge" {
  function_name = local.resource_name
  role          = aws_iam_role.purge.arn
  handler       = "purge.lambda_handler"
  runtime       = "python3.12"
  filename      = local.lambda_zip
  # Without this, updating purge.py wouldn't redeploy the function — Terraform only sees the
  # filename, not its contents.
  source_code_hash = filebase64sha256(local.lambda_zip)

  # A single UPDATE ... FROM statement, not a multi-step wait loop like secret-rotation's — 60s
  # default would almost certainly be enough, but this leaves real margin for a slow cold start
  # against RDS without inventing a number to justify further.
  timeout = 120

  # No reserved_concurrent_executions — same account-level floor constraint documented in
  # modules/aws/secret-rotation/main.tf (Checkov CKV_AWS_115, skipped in terraform-ci.yml).
  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      ARKCLOUD_APP_SECRET_ARN = var.arkcloud_app_secret_arn
      DB_HOST                 = var.db_host
      DB_PORT                 = tostring(var.db_port)
      DB_NAME                 = var.db_name
      DB_USERNAME             = var.db_username
      RETENTION_YEARS         = tostring(var.retention_years)
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.purge_vpc,
    aws_cloudwatch_log_group.purge,
  ]

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "purge_schedule" {
  name                = "${local.resource_name}-schedule"
  description         = "Triggers the RGPD retention purge Lambda (${var.schedule_expression})."
  schedule_expression = var.schedule_expression

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "purge_schedule" {
  rule = aws_cloudwatch_event_rule.purge_schedule.name
  arn  = aws_lambda_function.purge.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purge.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.purge_schedule.arn
}

# A failed purge run is silent by default: EventBridge doesn't retry a scheduled invocation
# indefinitely, and there's no user-facing symptom (customers just stay un-anonymized) — nothing
# breaks visibly. Same reasoning as secret-rotation's alarm.
resource "aws_cloudwatch_metric_alarm" "purge_errors" {
  count = var.alarm_sns_topic_arn != null ? 1 : 0

  alarm_name        = "${local.resource_name}-errors"
  alarm_description = "The RGPD retention purge Lambda failed. No customer data was anonymized on this run — check /aws/lambda/${local.resource_name}."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.purge.function_name
  }

  statistic           = "Sum"
  period              = 86400 # Matches the default daily schedule — see secret-rotation's alarm for why "notBreaching" pairs with a sparse metric.
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_sns_topic_arn]
  ok_actions    = [var.alarm_sns_topic_arn]

  tags = var.tags
}
