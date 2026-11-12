# Data tier NACL: only traffic to and from the VPC (and the peer VPC, if peered).
# A second layer behind security groups, so a mistaken SG rule can't expose a database
# to anything outside the VPC.
locals {
  data_allowed_cidrs = compact([var.vpc_cidr, local.peer_cidr])
}

resource "aws_network_acl" "data" {
  count      = var.create_data_subnets ? 1 : 0
  vpc_id     = aws_vpc.vpc.id
  subnet_ids = aws_subnet.data[*].id

  dynamic "ingress" {
    for_each = local.data_allowed_cidrs
    content {
      protocol   = -1
      rule_no    = 100 + ingress.key * 10
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = local.data_allowed_cidrs
    content {
      protocol   = -1
      rule_no    = 100 + egress.key * 10
      action     = "allow"
      cidr_block = egress.value
      from_port  = 0
      to_port    = 0
    }
  }

  tags = {
    Name = "${local.name}-data-nacl"
    Tier = "data"
  }
}
