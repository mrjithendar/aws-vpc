mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_vpc" { defaults = { id = "vpc-default", cidr_block = "172.31.0.0/16" } }
  mock_data "aws_route_tables" { defaults = { ids = ["rtb-a"] } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{}" } }
  mock_resource "aws_vpc" { defaults = { id = "vpc-new", ipv6_cidr_block = "2600:1f18:1234:5600::/56", default_network_acl_id = "acl-1" } }
  mock_resource "aws_s3_bucket" { defaults = { arn = "arn:aws:s3:::b" } }
}

run "dev" {
  command = apply
  variables {
    environment        = "dev"
    vpc_cidr           = "10.0.0.0/16"
    azs                = ["use1-az1", "use1-az2"]
    single_nat_gateway = true
    enable_peering     = true
  }
  assert {
    condition     = length(aws_nat_gateway.ngw) == 1 && length(aws_route.private_nat) == 2
    error_message = "single NAT"
  }
  assert {
    condition     = length(aws_route.peer_to_vpc) == 1 && length(aws_route.private_to_peer) == 2 && length(aws_route.data_to_peer) == 1
    error_message = "peering routes"
  }
  assert {
    condition     = alltrue([for s in concat(aws_subnet.public, aws_subnet.private) : s.map_public_ip_on_launch == false])
    error_message = "public ip"
  }
}

run "prod_cidrs" {
  command = apply
  variables {
    environment         = "prod"
    vpc_cidr            = "10.10.0.0/16"
    azs                 = ["use1-az1", "use1-az2", "use1-az4", "use1-az6"]
    enable_peering      = true
    enable_ipv6         = true
    interface_endpoints = ["ecr.api", "sts"]
    eks_cluster_name    = "roboshop-prod"
  }
  assert {
    condition     = length(aws_nat_gateway.ngw) == 4
    error_message = "nat per az"
  }
  assert {
    condition     = length(distinct(concat(local.public_cidrs, local.private_cidrs, local.data_cidrs, local.intra_cidrs))) == 16
    error_message = "dup cidrs"
  }
}

run "overlap_rejected" {
  command = plan
  variables {
    environment    = "dev"
    vpc_cidr       = "172.31.0.0/16"
    enable_peering = true
  }
  expect_failures = [aws_vpc_peering_connection.peer]
}
