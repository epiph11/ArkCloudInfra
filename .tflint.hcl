plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Azure-specific rules (naming conventions, deprecated arguments, invalid SKUs, etc.) — the
# base tflint ruleset only checks generic Terraform language issues, not anything Azure-aware.
plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
