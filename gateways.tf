resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-igw"
  }
}

# IPv6 egress for private subnets (outbound-only, the IPv6 counterpart of NAT).
resource "aws_egress_only_internet_gateway" "eigw" {
  count  = var.enable_ipv6 ? 1 : 0
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-eigw"
  }
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip-${var.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.igw]
}

# One NAT gateway per AZ (prod) so an AZ failure doesn't take out egress for the
# others, or one shared NAT gateway (single_nat_gateway = true) for non-prod.
resource "aws_nat_gateway" "ngw" {
  count             = local.nat_count
  connectivity_type = "public"
  allocation_id     = aws_eip.nat[count.index].id
  subnet_id         = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name}-ngw-${var.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.igw]
}
