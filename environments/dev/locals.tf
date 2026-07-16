locals {
  common_tags = merge(
    {
      environment = var.environment
      project     = "arkcloud"
      managed-by  = "terraform"
    },
    var.tags
  )
}
