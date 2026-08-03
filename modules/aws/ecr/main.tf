# Sprint 5, Step 11 — ECR as the provisional AWS registry (task #33's decision: ECR now,
# JFrog Artifactory migration stays a separate later piece of work rather than blocking ECS on
# standing up an external tool). ArkCloud's CI (arkcloud-backend-ci.yml / arkcloud-frontend-ci.yml,
# in the ArkCloud repo) currently only pushes to GHCR — it needs a follow-up change to also push
# here before any image actually exists in these repos for ECS to pull. Until then, `terraform
# apply` on modules/aws/ecs will succeed (it only creates the ECS service/task definition) but
# the tasks themselves will fail to start with CannotPullContainerError, the AWS equivalent of
# Sprint 4's "image never existed" bug — expected, not a surprise, tracked as a separate task.

resource "aws_ecr_repository" "api" {
  name = "arkcloud-${var.name_prefix}/api"

  image_tag_mutability = "MUTABLE" # matches the existing "dev" tag being re-pushed on every merge, same as GHCR today
  force_delete         = true      # dev-tier: allow `terraform destroy` to remove a repo that still has images, no manual purge first

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_repository" "web" {
  name = "arkcloud-${var.name_prefix}/web"

  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# Untagged-only cleanup — see variables.tf. Identical policy on both repos, defined once as a
# local to avoid repeating the JSON twice.
locals {
  untagged_expiry_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.untagged_image_expiry_days
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy     = local.untagged_expiry_policy
}

resource "aws_ecr_lifecycle_policy" "web" {
  repository = aws_ecr_repository.web.name
  policy     = local.untagged_expiry_policy
}
