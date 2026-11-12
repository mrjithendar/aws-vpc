resource "aws_vpc" "vpc" {
  cidr_block                       = var.vpc_cidr
  instance_tenancy                 = "default"
  assign_generated_ipv6_cidr_block = var.enable_ipv6

  # Required for EFS, private hosted zones and interface endpoint private DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

# Take over the default security group and strip all rules (CIS / Security Hub EC2.2).
# Nothing should rely on it; workloads use their own security groups.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${local.name}-default-sg-DO-NOT-USE"
  }
}

# Adopt the default NACL so changes to it show up as drift. Allows everything; the data
# tier has its own stricter NACL (see nacl.tf).
resource "aws_default_network_acl" "default" {
  default_network_acl_id = aws_vpc.vpc.default_network_acl_id

  ingress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  dynamic "ingress" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol        = -1
      rule_no         = 101
      action          = "allow"
      ipv6_cidr_block = "::/0"
      from_port       = 0
      to_port         = 0
    }
  }

  dynamic "egress" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol        = -1
      rule_no         = 101
      action          = "allow"
      ipv6_cidr_block = "::/0"
      from_port       = 0
      to_port         = 0
    }
  }

  # Subnet associations are managed by AWS and by aws_network_acl.data.
  lifecycle {
    ignore_changes = [subnet_ids]
  }

  tags = {
    Name = "${local.name}-default-nacl"
  }
}
