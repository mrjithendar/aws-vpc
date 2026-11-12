terraform {
  # >= 1.10 is required for native S3 state locking (use_lockfile).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Optional: let the pipeline assume a deploy role instead of using static keys.
  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "terraform-aws-vpc-${var.environment}"
    }
  }

  # Applied to every taggable resource; per-resource blocks only add Name/Tier.
  default_tags {
    tags = local.common_tags
  }
}
