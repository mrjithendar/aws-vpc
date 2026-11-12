#--------------------------------------------------------------------
# General
#--------------------------------------------------------------------
variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "assume_role_arn" {
  description = "Optional IAM role for Terraform to assume (CI deploy role). Null uses the ambient credentials."
  type        = string
  default     = null
}

variable "environment" {
  description = "Environment name, used in resource names and tags (e.g. dev, prod)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,16}$", var.environment))
    error_message = "environment must be 2-16 chars of lowercase letters, digits or '-'."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "roboshop"
}

variable "userid" {
  description = "Owner/user id added as the Owner tag. Empty string skips the tag."
  type        = string
  default     = ""
}

variable "team" {
  description = "Team tag value."
  type        = string
  default     = "DKODE Tech"
}

variable "team_email" {
  description = "Contact email tag value."
  type        = string
  default     = "team@decodedevops.com"
}

variable "organization" {
  description = "Organization tag value."
  type        = string
  default     = "Decode DevOps"
}

#--------------------------------------------------------------------
# Addressing
#--------------------------------------------------------------------
variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC. Must be a /16; the subnet plan in _locals.tf is laid out for a /16."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(split("/", var.vpc_cidr)[1] == "16", false)
    error_message = "vpc_cidr must be a valid IPv4 /16, e.g. 10.0.0.0/16."
  }
}

variable "azs" {
  description = <<-EOT
    Availability Zone IDs (not names) to use, e.g. use1-az1. AZ IDs map to the same
    physical zone in every account, unlike names. use1-az3 is avoided in us-east-1
    because it is capacity-constrained and lacks newer instance types.
  EOT
  type        = list(string)
  default     = ["use1-az1", "use1-az2", "use1-az4"]

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 4 && length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must contain 2-4 distinct AZ IDs."
  }
}

variable "enable_ipv6" {
  description = "Assign an Amazon-provided /56 and dual-stack the public and private subnets."
  type        = bool
  default     = false
}

variable "create_data_subnets" {
  description = "Create the isolated data tier (no internet route) for RDS/ElastiCache/DocumentDB."
  type        = bool
  default     = true
}

variable "create_intra_subnets" {
  description = "Create the isolated intra tier (no internet route), e.g. for EKS control-plane ENIs."
  type        = bool
  default     = true
}

#--------------------------------------------------------------------
# Egress
#--------------------------------------------------------------------
variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ. Cheaper; loses AZ-independent egress. Use for non-prod only."
  type        = bool
  default     = false
}

#--------------------------------------------------------------------
# Peering
#--------------------------------------------------------------------
variable "enable_peering" {
  description = "Peer this VPC with another VPC in the same account and region (e.g. where Jenkins runs)."
  type        = bool
  default     = false
}

variable "peer_vpc_id" {
  description = "VPC to peer with. Null means the account's default VPC."
  type        = string
  default     = null
}

#--------------------------------------------------------------------
# Endpoints
#--------------------------------------------------------------------
variable "interface_endpoints" {
  description = <<-EOT
    Interface endpoint service short names (e.g. ecr.api, ecr.dkr, sts, logs). Each costs
    about $7.30/month per AZ plus data; worth it when the same traffic would cross NAT at
    $0.045/GB. S3 and DynamoDB gateway endpoints are always created (free).
  EOT
  type        = list(string)
  default     = []
}

#--------------------------------------------------------------------
# Observability
#--------------------------------------------------------------------
variable "enable_flow_logs" {
  description = "Send VPC Flow Logs to a dedicated S3 bucket."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Days to keep flow log objects in S3."
  type        = number
  default     = 90
}

#--------------------------------------------------------------------
# EKS integration
#--------------------------------------------------------------------
variable "eks_cluster_name" {
  description = "If set, adds kubernetes.io/cluster/<name> and karpenter.sh/discovery tags to private subnets."
  type        = string
  default     = ""
}
