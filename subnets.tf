# Public tier: load balancers and NAT gateways only. No auto-assigned public IPs;
# anything that needs one asks for it explicitly.
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.vpc.id
  availability_zone_id    = var.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = false

  ipv6_cidr_block                 = var.enable_ipv6 ? cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, local.public_ipv6_index + count.index) : null
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = {
    Name                     = "${local.name}-public-${var.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private tier: applications and EKS nodes/pods. Egress through NAT.
resource "aws_subnet" "private" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.vpc.id
  availability_zone_id    = var.azs[count.index]
  cidr_block              = local.private_cidrs[count.index]
  map_public_ip_on_launch = false

  ipv6_cidr_block                 = var.enable_ipv6 ? cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, local.private_ipv6_index + count.index) : null
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = merge(local.eks_private_tags, {
    Name                              = "${local.name}-private-${var.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# Data tier: managed databases/caches. No route to the internet.
resource "aws_subnet" "data" {
  count                   = var.create_data_subnets ? local.az_count : 0
  vpc_id                  = aws_vpc.vpc.id
  availability_zone_id    = var.azs[count.index]
  cidr_block              = local.data_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-data-${var.azs[count.index]}"
    Tier = "data"
  }
}

# Intra tier: things that never need the internet (e.g. EKS control-plane ENIs).
resource "aws_subnet" "intra" {
  count                   = var.create_intra_subnets ? local.az_count : 0
  vpc_id                  = aws_vpc.vpc.id
  availability_zone_id    = var.azs[count.index]
  cidr_block              = local.intra_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-intra-${var.azs[count.index]}"
    Tier = "intra"
  }
}
