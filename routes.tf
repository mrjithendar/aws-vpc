# All routes are separate aws_route resources (no inline route blocks), so peering,
# endpoint and future TGW routes can be added without Terraform fighting itself.

#--------------------------------------------------------------------
# Public: one shared table, default route to the IGW
#--------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-public-rt"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route" "public_internet_ipv6" {
  count                       = var.enable_ipv6 ? 1 : 0
  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#--------------------------------------------------------------------
# Private: one table per AZ, default route to that AZ's NAT gateway
# (or the shared one when single_nat_gateway = true)
#--------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-private-rt-${var.azs[count.index]}"
    Tier = "private"
  }
}

resource "aws_route" "private_nat" {
  count                  = local.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.ngw[min(count.index, local.nat_count - 1)].id
}

resource "aws_route" "private_ipv6_egress" {
  count                       = var.enable_ipv6 ? local.az_count : 0
  route_table_id              = aws_route_table.private[count.index].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw[0].id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#--------------------------------------------------------------------
# Data: one table, no default route (local + peering only)
#--------------------------------------------------------------------
resource "aws_route_table" "data" {
  count  = var.create_data_subnets ? 1 : 0
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-data-rt"
    Tier = "data"
  }
}

resource "aws_route_table_association" "data" {
  count          = var.create_data_subnets ? local.az_count : 0
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data[0].id
}

#--------------------------------------------------------------------
# Intra: one table, no default route (local + gateway endpoints only)
#--------------------------------------------------------------------
resource "aws_route_table" "intra" {
  count  = var.create_intra_subnets ? 1 : 0
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-intra-rt"
    Tier = "intra"
  }
}

resource "aws_route_table_association" "intra" {
  count          = var.create_intra_subnets ? local.az_count : 0
  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra[0].id
}
