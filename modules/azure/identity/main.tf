# Deliberately generic (scope/principal/role as inputs) rather than hardcoded to "App Service
# reading the Key Vault" — the same module grants any future principal (e.g. a GitHub Actions
# OIDC service principal, an ECS task role equivalent) any built-in role, without new code.
resource "azurerm_role_assignment" "this" {
  scope                = var.scope
  role_definition_name = var.role_definition_name
  principal_id         = var.principal_id
}
