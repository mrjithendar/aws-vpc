#--------------------------------------------------------------------
# Gateway endpoints (free): S3 and DynamoDB traffic skips the NAT gateway.
# Attached to private and intra route tables. The data tier is intentionally left
# off, so it has no path out of the VPC.
#--------------------------------------------------------------------
locals {
  gateway_endpoint_route_tables = concat(
    aws_route_table.private[*].id,
    aws_route_table.intra[*].id,
  )
}

resource "aws_vpc_endpoint" "gateway" {
  for_each          = toset(["s3", "dynamodb"])
  vpc_id            = aws_vpc.vpc.id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_tables

  tags = {
    Name = "${local.name}-vpce-${each.key}"
  }
}

#--------------------------------------------------------------------
# Interface endpoints (paid, opt-in via var.interface_endpoints)
#--------------------------------------------------------------------
resource "aws_security_group" "vpce" {
  count       = length(var.interface_endpoints) > 0 ? 1 : 0
  name        = "${local.name}-vpce"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-vpce-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https" {
  count             = length(var.interface_endpoints) > 0 ? 1 : 0
  security_group_id = aws_security_group.vpce[0].id
  description       = "HTTPS from VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(var.interface_endpoints)
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name}-vpce-${replace(each.key, ".", "-")}"
  }
}
