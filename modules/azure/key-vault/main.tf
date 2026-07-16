# RBAC authorization model (enable_rbac_authorization = true) rather than the legacy access
# policy model — role assignments (see modules/azure/identity) are granted the same way as
# any other Azure resource, no separate Key Vault-specific policy syntax to maintain.
#
# No secrets are created here. Values (DB password, JWT key) are set post-apply, out of band
# (az keyvault secret set / CI secret injection) — never as a Terraform resource, so they never
# land in the .tf source or get echoed in a `plan` diff. The remote state itself is still the
# blast radius to be aware of: it would contain any secret set via Terraform, which is exactly
# why we don't do that here even though the state storage is versioned/locked (Step 4).
resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  # Renamed from enable_rbac_authorization in azurerm provider v4 — the old name still works
  # but is deprecated and slated for removal in v5, so using the new name now avoids a
  # forced rename later.
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  tags = var.tags
}
