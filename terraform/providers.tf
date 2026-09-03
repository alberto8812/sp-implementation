provider "aws" {
  region = var.aws_region

  # Applied to every resource that supports tagging, so a forgotten resource
  # after a failed destroy is still traceable back to this lab.
  default_tags {
    tags = local.common_tags
  }
}
