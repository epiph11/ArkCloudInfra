provider "azurerm" {
  features {}
}

# Used only to resolve the current tenant id for the Key Vault module — never hardcode a
# tenant id in .tf source, it's account/subscription-specific.
data "azurerm_client_config" "current" {}

# Sprint 5 — eu-west-1 (Ireland), chosen over eu-west-3 (Paris) for AWS service maturity/
# availability rather than latency to westeurope (Azure) — the two clouds don't talk to each
# other directly in this architecture, so cross-cloud latency isn't a real factor here.
#
# Auth: OIDC federated, same shape as the Azure setup in README §6 — no static AWS access
# key/secret stored anywhere. Unlike azurerm (which reads ARM_USE_OIDC directly), the AWS
# exchange happens one level up, in the GitHub Actions workflow step (`aws-actions/configure-
# aws-credentials` with `role-to-assume: <IAM role ARN>`), which populates the standard
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN env vars for the job — this
# provider block then just picks those up via the default credential chain, no explicit
# assume-role config needed here. The IAM role + trust policy it assumes are bootstrapped
# once, manually (README §11, one-shot, same chicken-and-egg reason as the Azure App
# Registration in §6).
provider "aws" {
  region = var.aws_region
}
