locals {
  # "owner" is baked in here rather than left to var.tags/terraform.tfvars: the CI apply job
  # (.github/workflows/terraform-ci.yml, job "apply", runs on every push to main) checks out the
  # repo fresh and never sees terraform.tfvars — it's gitignored — so var.tags always resolved to
  # its {} default there. Every local apply added "owner", every CI apply on the next push
  # silently stripped it again. Since the owner is a static fact about this project (not
  # environment-specific, nothing to override per-environment), committing it here removes the
  # whole class of drift instead of trying to keep two apply paths' variables in sync.
  common_tags = merge(
    {
      environment = var.environment
      project     = "arkcloud"
      managed-by  = "terraform"
      owner       = "epiphane"
    },
    var.tags
  )
}
