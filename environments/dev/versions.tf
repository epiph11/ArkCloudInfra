terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Sprint 5 — same root module, same state file as Azure. Multi-cloud within one
    # environment/dev deliberately, per docs/infra-roadmap.md: one `terraform apply` per
    # environment provisions both clouds, rather than splitting into a second root module
    # with its own state to keep in sync by hand.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
