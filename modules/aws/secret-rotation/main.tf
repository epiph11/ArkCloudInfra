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
}

# Its own security group rather than reusing sg-ecs-api: the ingress rule added to sg-database
# below should name exactly this Lambda, so the database's allowed-source list stays a precise
# statement of who can reach it.
resource "aws_security_group" "rotation" {
  name        = "secret-rotation-${var.name_prefix}"
  description = "Postgres password rotation Lambda - egress to RDS and AWS APIs, no ingress."
  vpc_id      = var.vpc_id

  # No ingress block at all — nothing ever connects TO a rotation Lambda.

  egress {
    description = "All outbound - RDS on the private subnets, Secrets Manager/RDS/ECS APIs via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-secret-rotation-${var.name_prefix}" })
}

# The testSecret step connects to the database for real to prove the new credential works before
# it's promoted — so sg-database has to accept this Lambda as a source.
resource "aws_vpc_security_group_ingress_rule" "database_from_rotation" {
  security_group_id            = var.database_security_group_id
  description                  = "Postgres rotation Lambda (testSecret step)"
  referenced_security_group_id = aws_security_group.rotation.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
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

resource "aws_iam_role" "rotation" {
  name               = "secret-rotation-${var.name_prefix}"
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

  statement {
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

  statement {
    sid       = "RedeployApiServiceOnly"
    actions   = ["ecs:UpdateService"]
    resources = [var.ecs_service_arn]
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotation"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

resource "aws_cloudwatch_log_group" "rotation" {
  name              = "/aws/lambda/secret-rotation-${var.name_prefix}"
  retention_in_days = 30 # Same window as the other log groups in this project.

  tags = var.tags
}

resource "aws_lambda_function" "rotation" {
  function_name = "secret-rotation-${var.name_prefix}"
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

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = [aws_security_group.rotation.id]
  }

  environment {
    variables = {
      DB_INSTANCE_IDENTIFIER = var.db_instance_identifier
      DB_HOST                = var.db_host
      DB_PORT                = tostring(var.db_port)
      DB_NAME                = var.db_name
      DB_USERNAME            = var.db_username
      ECS_CLUSTER            = var.ecs_cluster_name
      ECS_SERVICE            = var.ecs_service_name
    }
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
