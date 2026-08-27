# Same principle as modules/azure/key-vault (see that module's comment in full): only the
# secret CONTAINERS are created here. Values are set out-of-band — `aws secretsmanager
# put-secret-value` locally, or a CI secret piped in at deploy time — never as a Terraform
# resource (no aws_secretsmanager_secret_version here), so they never land in the .tf source
# or get echoed in a `plan` diff.
#
# One exception already exists on both clouds and can't be avoided: the RDS/PostgreSQL engine
# resource itself requires its master password as a direct Terraform argument
# (aws_db_instance.this.password here, azurerm_postgresql_flexible_server.administrator_password
# on the Azure side) — that value does land in state either way. These two secrets are for
# everything that ISN'T forced through an engine resource's own schema: the JWT signing key
# today, anything else ArkCloud.API needs later.
#
# No IAM policy granting read access lives here — that's attached to the ECS task role once it
# exists (Step 11), the same way modules/azure/identity's role assignment only exists once both
# Key Vault and the App Service are provisioned. These resources just need to exist first so
# Step 11 has an ARN to point the task role's policy at.

resource "aws_secretsmanager_secret" "postgres" {
  name                    = "arkcloud/${var.name_prefix}/postgres"
  description             = "ArkCloud API PostgreSQL (RDS) connection secret. Value set out-of-band, never via Terraform."
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "arkcloud/${var.name_prefix}/jwt"
  description             = "ArkCloud API JWT signing key, AWS counterpart to the Jwt--Key secret in Azure Key Vault. Value set out-of-band."
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

# arkcloud_app — the least-privilege, DML-only Postgres role introduced in Sprint 6 to close the
# STRIDE "Elevation of privilege" finding (ArkCloud.API currently connects as the RDS master
# user). Unlike postgres/jwt above, this secret's real value is never set out-of-band by a human
# — modules/aws/secret-rotation, instantiated a second time in "app" mode
# (environments/dev/main.tf), owns its entire lifecycle: it creates the role (if missing),
# rotates its password, and promotes the new version, all inside the same Lambda that already
# handles the master password rotation.
#
# Secrets Manager's rotation API needs an existing AWSCURRENT version to rotate away from before
# it can run for the first time (real failure mode already hit once in this project — see bug
# 6.11 in the Sprint 5 report, ResourceNotFoundException for staging label AWSCURRENT). So this
# resource seeds one with a throwaway random value that is never used to authenticate anything —
# the rotation Lambda's first run (triggered immediately on attaching rotation, same as the
# master secret) overwrites it with the real, live password within the same `terraform apply`.
#
# ignore_changes is required for the same reason modules/azure/postgresql and modules/aws/rds
# ignore_changes on their admin password: once the Lambda has rotated this secret, its live value
# no longer matches what Terraform put here, and without ignore_changes the next `terraform plan`
# would want to reset it back to this placeholder — silently undoing every rotation since.
resource "random_password" "arkcloud_app_bootstrap" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "arkcloud_app" {
  name                    = "arkcloud/${var.name_prefix}/arkcloud-app-role"
  description             = "ArkCloud.API's least-privilege DML-only Postgres role (arkcloud_app) - STRIDE elevation-of-privilege remediation, Sprint 6. Created and rotated entirely by modules/aws/secret-rotation (app-role mode), not set out-of-band."
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "arkcloud_app_bootstrap" {
  secret_id     = aws_secretsmanager_secret.arkcloud_app.id
  secret_string = "Host=placeholder;Port=5432;Database=placeholder;Username=arkcloud_app;Password=${random_password.arkcloud_app_bootstrap.result};Ssl Mode=Require"

  lifecycle {
    ignore_changes = [secret_string]
  }
}
