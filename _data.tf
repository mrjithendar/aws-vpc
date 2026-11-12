data "aws_caller_identity" "current" {}

# Peer VPC: an explicit ID, or the account default VPC (looked up with default = true,
# which does not depend on anyone having tagged it).
data "aws_vpc" "peer" {
  count   = var.enable_peering ? 1 : 0
  id      = var.peer_vpc_id
  default = var.peer_vpc_id == null ? true : null
}

data "aws_route_tables" "peer" {
  count  = var.enable_peering ? 1 : 0
  vpc_id = data.aws_vpc.peer[0].id
}
