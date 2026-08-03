variable "name_prefix" {
  description = "Prefixed onto every repository name in this module, e.g. \"arkcloud-dev\"."
  type        = string
}

variable "untagged_image_expiry_days" {
  description = "Untagged images (superseded digests after a re-push of the same tag) are cleaned up after this many days — tagged images (dev, any real release tag) are never touched by this policy. Keeps the repo from growing unbounded without ever deleting an image something might still reference by tag."
  type        = number
  default     = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
