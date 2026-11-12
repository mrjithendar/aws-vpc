# One-time bootstrap: GitHub OIDC provider + the two roles the workflow assumes.
# Apply once from a workstation with admin credentials (local state is fine):
#   cd bootstrap/github-oidc && terraform init && terraform apply
# Then put the output ARNs into GitHub repo/environment variables (see README).

terraform {
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
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the roles."
  type        = string
  default     = "mrjithendar/aws-vpc"
}

variable "default_branch" {
  type    = string
  default = "master"
}

variable "environments" {
  description = "GitHub environments allowed to assume the apply role."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state."
  type        = string
  default     = "jithendardharmapuri"
}

variable "create_oidc_provider" {
  description = "Set false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}

data "aws_caller_identity" "current" {}

locals {
  oidc_host    = "token.actions.githubusercontent.com"
  oidc_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_host}"
  state_prefix = "terraform/vpc/"
  flow_bucket  = "arn:aws:s3:::*-vpc-flowlogs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

#--------------------------------------------------------------------
# Trust policies
#--------------------------------------------------------------------
# Plan role: PRs from this repo and pushes to the default branch.
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/${var.default_branch}",
      ]
    }
  }
}

# Apply role: only jobs running in the named GitHub environments.
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for e in var.environments : "repo:${var.github_repository}:environment:${e}"]
    }
  }
}

#--------------------------------------------------------------------
# Shared: state bucket access (read state, write the lock file)
#--------------------------------------------------------------------
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
  statement {
    sid       = "ReadWriteStateAndLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/${local.state_prefix}*"]
  }
}

#--------------------------------------------------------------------
# Plan role (read-only on AWS, plus state lock)
#--------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "gha-aws-vpc-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state.json
}

#--------------------------------------------------------------------
# Apply role (VPC + flow-log bucket + state)
#--------------------------------------------------------------------
resource "aws_iam_role" "apply" {
  name                 = "gha-aws-vpc-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply_vpc" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
}

data "aws_iam_policy_document" "apply_extra" {
  source_policy_documents = [data.aws_iam_policy_document.state.json]

  statement {
    sid       = "FlowLogBucket"
    actions   = ["s3:*"]
    resources = [local.flow_bucket, "${local.flow_bucket}/*"]
  }

  statement {
    sid       = "FlowLogDeliveryToS3"
    actions   = ["logs:CreateLogDelivery", "logs:DeleteLogDelivery", "logs:GetLogDelivery", "logs:ListLogDeliveries"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadOnlyLookups"
    actions   = ["ec2:Describe*", "ec2:Get*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_extra" {
  name   = "aws-vpc-deploy"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_extra.json
}

output "plan_role_arn" {
  description = "Set as repo variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as variable AWS_ROLE_ARN on the dev and prod GitHub environments."
  value       = aws_iam_role.apply.arn
}
