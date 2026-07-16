provider "azurerm" {
  features {}
}

# Used only to resolve the current tenant id for the Key Vault module — never hardcode a
# tenant id in .tf source, it's account/subscription-specific.
data "azurerm_client_config" "current" {}
