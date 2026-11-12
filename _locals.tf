locals {
  name = "${var.name_prefix}-${var.environment}"

  common_tags = merge(
    {
      Team         = var.team
      Email        = var.team_email
      Environment  = var.environment
      Organization = var.organization
      Createdby    = "Terraform"
      Repository   = "mrjithendar/aws-vpc"
    },
    var.userid != "" ? { Owner = var.userid } : {}
  )

  az_count = length(var.azs)

  #------------------------------------------------------------------
  # Subnet plan for a /16 (example: 10.0.0.0/16). Each tier has its own
  # fixed netnum range, so adding an AZ never collides with another tier.
  #
  #   tier     size  netnums  example (3 AZs)               usable IPs/subnet
  #   public   /24   0-3      10.0.0.0  - 10.0.2.0/24       251
  #   data     /24   10-13    10.0.10.0 - 10.0.12.0/24      251
  #   intra    /24   20-23    10.0.20.0 - 10.0.22.0/24      251
  #   private  /20   2-5      10.0.32.0 - 10.0.64.0/20      4091
  #   (spare)        10.0.96.0 - 10.0.255.255 left for growth
  #------------------------------------------------------------------
  public_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  data_cidrs    = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  intra_cidrs   = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
  private_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, 2 + i)]

  # IPv6 /64 indexes inside the VPC /56 (only used when enable_ipv6 = true)
  public_ipv6_index  = 0
  private_ipv6_index = 16

  nat_count = var.single_nat_gateway ? 1 : local.az_count

  #------------------------------------------------------------------
  # Peering CIDR overlap check: two CIDRs overlap if they share the same
  # leading bits up to the shorter prefix length.
  #------------------------------------------------------------------
  peer_cidr = var.enable_peering ? data.aws_vpc.peer[0].cidr_block : null

  vpc_base_int = sum([for i, o in split(".", cidrhost(var.vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - i)])
  vpc_prefix   = tonumber(split("/", var.vpc_cidr)[1])

  peer_base_int = local.peer_cidr == null ? 0 : sum([for i, o in split(".", cidrhost(local.peer_cidr, 0)) : tonumber(o) * pow(256, 3 - i)])
  peer_prefix   = local.peer_cidr == null ? 32 : tonumber(split("/", local.peer_cidr)[1])

  min_prefix    = min(local.vpc_prefix, local.peer_prefix)
  cidrs_overlap = local.peer_cidr == null ? false : floor(local.vpc_base_int / pow(2, 32 - local.min_prefix)) == floor(local.peer_base_int / pow(2, 32 - local.min_prefix))

  # Load balancer / cluster discovery tags
  eks_private_tags = var.eks_cluster_name == "" ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "karpenter.sh/discovery"                        = var.eks_cluster_name
  }
}
