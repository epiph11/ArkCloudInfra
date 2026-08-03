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
