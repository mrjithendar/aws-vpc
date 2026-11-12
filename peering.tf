# Same-account, same-region peering (e.g. to the VPC where Jenkins runs).
# Peering is not transitive: for more than two or three VPCs, use a Transit Gateway.
resource "aws_vpc_peering_connection" "peer" {
  count       = var.enable_peering ? 1 : 0
  vpc_id      = aws_vpc.vpc.id
  peer_vpc_id = data.aws_vpc.peer[0].id
  auto_accept = true

  tags = {
    Name = "${local.name}-pcx-to-${data.aws_vpc.peer[0].id}"
  }

  lifecycle {
    precondition {
      condition     = !local.cidrs_overlap
      error_message = "Peer VPC CIDR ${local.peer_cidr} overlaps ${var.vpc_cidr}; peering requires non-overlapping CIDRs."
    }
  }
}

# Let each side resolve the other's private DNS hostnames to private IPs.
resource "aws_vpc_peering_connection_options" "peer" {
  count                     = var.enable_peering ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# This VPC -> peer: from private and data tiers (where things that talk to the peer live).
resource "aws_route" "private_to_peer" {
  count                     = var.enable_peering ? local.az_count : 0
  route_table_id            = aws_route_table.private[count.index].id
  destination_cidr_block    = local.peer_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

resource "aws_route" "data_to_peer" {
  count                     = var.enable_peering && var.create_data_subnets ? 1 : 0
  route_table_id            = aws_route_table.data[0].id
  destination_cidr_block    = local.peer_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# Peer -> this VPC: return routes in every route table of the peer VPC.
resource "aws_route" "peer_to_vpc" {
  for_each                  = var.enable_peering ? toset(data.aws_route_tables.peer[0].ids) : toset([])
  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}
