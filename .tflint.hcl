plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Azure-specific rules (naming conventions, deprecated arguments, invalid SKUs, etc.) — the
# base tflint ruleset only checks generic Terraform language issues, not anything Azure-aware.
#
# Bumped 0.27.0 -> 0.32.0: the 0.27.0 release's binary asset started returning a persistent
# 500 from GitHub's release-asset CDN (confirmed via the GitHub API that 0.27.0's asset IDs are
# ~180M vs ~405M for the current release — an old release, not a rate-limit issue, since
# checksums.txt succeeded once GITHUB_TOKEN was added but the actual .zip still 500'd).
# v0.32.0 removed a handful of naming-convention rules for resources this repo doesn't use
# (Container Registry, Data Factory, AKS cluster name) — no functional impact here.
plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Sprint 5 — AWS-specific rules (deprecated arguments, invalid instance types, etc.), same
# reasoning as azurerm above: the base ruleset doesn't know AWS resource schemas.
plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
