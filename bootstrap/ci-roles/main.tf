# One-time bootstrap: the two IAM roles every CI system uses to deploy aws-vpc, and the
# OIDC providers that let GitHub Actions and GitLab CI assume them without static keys.
# Apply once from a workstation with admin credentials (local state is fine):
#   cd bootstrap/ci-roles && terraform init && terraform apply
#
#   plan role  : ReadOnlyAccess + state read/write (S3 lock file). Used for every plan.
#   apply role : VPC + flow-log bucket + state. Used only for applies.
#
# Who can assume them:
#   GitHub Actions : plan  <- PRs and pushes to the default branch
#                    apply <- jobs running in the listed GitHub environments (dev, prod)
#   GitLab CI      : plan  <- any branch / MR pipeline of the project
#                    apply <- the default branch only (make it a protected branch)
#   Jenkins        : plan + apply <- the listed IAM role ARNs (e.g. the agents' instance role)

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

#--------------------------------------------------------------------
# Inputs
#--------------------------------------------------------------------
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state."
  type        = string
  default     = "jithendardharmapuri"
}

variable "default_branch" {
  type    = string
  default = "master"
}

# GitHub Actions
variable "enable_github" {
  type    = bool
  default = true
}

variable "github_repository" {
  description = "owner/repo allowed to assume the roles."
  type        = string
  default     = "mrjithendar/aws-vpc"
}

variable "github_environments" {
  description = "GitHub environments allowed to assume the apply role."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}

# GitLab CI
variable "enable_gitlab" {
  type    = bool
  default = false
}

variable "gitlab_url" {
  description = "GitLab instance URL (gitlab.com or self-managed)."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = "group/project allowed to assume the roles."
  type        = string
  default     = "mrjithendar/aws-vpc"
}

variable "create_gitlab_oidc_provider" {
  description = "Set false if the account already has an OIDC provider for this GitLab URL."
  type        = bool
  default     = true
}

# Jenkins
variable "jenkins_role_arns" {
  description = "IAM role ARNs of the Jenkins agents (instance profile roles) allowed to assume both roles."
  type        = list(string)
  default     = []
}

#--------------------------------------------------------------------
# Locals
#--------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  github_host = "token.actions.githubusercontent.com"
  github_arn  = "arn:aws:iam::${local.account_id}:oidc-provider/${local.github_host}"

  gitlab_host = trimsuffix(replace(var.gitlab_url, "https://", ""), "/")
  gitlab_arn  = "arn:aws:iam::${local.account_id}:oidc-provider/${local.gitlab_host}"

  state_prefix = "terraform/vpc/"
  flow_bucket  = "arn:aws:s3:::*-vpc-flowlogs-${local.account_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.enable_github && var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_host}"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count          = var.enable_gitlab && var.create_gitlab_oidc_provider ? 1 : 0
  url            = "https://${local.gitlab_host}"
  client_id_list = ["sts.amazonaws.com"] # matches id_tokens.aud in .gitlab-ci.yml
}

#--------------------------------------------------------------------
# Trust policies
#--------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  dynamic "statement" {
    for_each = var.enable_github ? [1] : []
    content {
      sid     = "GitHubActions"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.github_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.github_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.github_host}:sub"
        values = [
          "repo:${var.github_repository}:pull_request",
          "repo:${var.github_repository}:ref:refs/heads/${var.default_branch}",
        ]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_gitlab ? [1] : []
    content {
      sid     = "GitLabCI"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.gitlab_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.gitlab_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringLike"
        variable = "${local.gitlab_host}:sub"
        values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.jenkins_role_arns) > 0 ? [1] : []
    content {
      sid     = "Jenkins"
      actions = ["sts:AssumeRole", "sts:TagSession"]
      principals {
        type        = "AWS"
        identifiers = var.jenkins_role_arns
      }
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  dynamic "statement" {
    for_each = var.enable_github ? [1] : []
    content {
      sid     = "GitHubActionsEnvironments"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.github_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.github_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.github_host}:sub"
        values   = [for e in var.github_environments : "repo:${var.github_repository}:environment:${e}"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_gitlab ? [1] : []
    content {
      sid     = "GitLabDefaultBranch"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.gitlab_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.gitlab_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.gitlab_host}:sub"
        values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.default_branch}"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.jenkins_role_arns) > 0 ? [1] : []
    content {
      sid     = "Jenkins"
      actions = ["sts:AssumeRole", "sts:TagSession"]
      principals {
        type        = "AWS"
        identifiers = var.jenkins_role_arns
      }
    }
  }
}

#--------------------------------------------------------------------
# Permissions
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

resource "aws_iam_role" "plan" {
  name                 = "ci-aws-vpc-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = var.enable_github || var.enable_gitlab || length(var.jenkins_role_arns) > 0
      error_message = "Enable at least one CI system (enable_github, enable_gitlab or jenkins_role_arns)."
    }
  }
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

resource "aws_iam_role" "apply" {
  name                 = "ci-aws-vpc-apply"
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

#--------------------------------------------------------------------
# Outputs
#--------------------------------------------------------------------
output "plan_role_arn" {
  description = "GitHub: repo variable AWS_PLAN_ROLE_ARN. GitLab/Jenkins: AWS_VPC_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "GitHub: AWS_ROLE_ARN on the dev/prod environments. GitLab/Jenkins: AWS_VPC_APPLY_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}
