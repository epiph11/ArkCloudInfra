# Remote state — see ArkCloudInfra/README.md §2 for how this storage account was bootstrapped.
# One key per environment; staging/prod will use "staging.terraform.tfstate" /
# "prod.terraform.tfstate" in the same container, never sharing a key/state with dev.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "arkcloudstatestore"
    container_name       = "terraform"
    key                  = "dev.terraform.tfstate"

    # Authenticates via Azure AD (RBAC role on the storage account) instead of an access key —
    # works both for `az login` locally and for GitHub Actions' OIDC token in CI (see
    # ArkCloudInfra/README.md §6 for the one-time Azure setup this requires).
    use_azuread_auth = true
    use_oidc         = true
  }
}
