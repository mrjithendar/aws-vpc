output "vpc_id" {
  value = aws_vpc.vpc.id
}

output "vpc_cidr" {
  value = aws_vpc.vpc.cidr_block
}

output "vpc_ipv6_cidr" {
  value = var.enable_ipv6 ? aws_vpc.vpc.ipv6_cidr_block : null
}

output "azs" {
  description = "AZ IDs in subnet order."
  value       = var.azs
}

output "availability_zones" {
  description = "AZ names in subnet order (names differ per account; IDs do not)."
  value       = aws_subnet.private[*].availability_zone
}

output "public_subnets" {
  value = aws_subnet.public[*].id
}

output "private_subnets" {
  value = aws_subnet.private[*].id
}

output "data_subnets" {
  value = aws_subnet.data[*].id
}

output "intra_subnets" {
  value = aws_subnet.intra[*].id
}

output "subnets" {
  description = "Private + public subnet IDs (kept for backward compatibility)."
  value       = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
}

output "public_rt" {
  value = aws_route_table.public.id
}

output "private_rt" {
  value = aws_route_table.private[*].id
}

output "data_rt" {
  value = try(aws_route_table.data[0].id, null)
}

output "intra_rt" {
  value = try(aws_route_table.intra[0].id, null)
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.ngw[*].id
}

output "nat_public_ips" {
  description = "Egress IPs to allow-list with third parties."
  value       = aws_eip.nat[*].public_ip
}

output "vpc_peering_connection_id" {
  value = try(aws_vpc_peering_connection.peer[0].id, null)
}

output "vpc_endpoint_ids" {
  value = merge(
    { for k, v in aws_vpc_endpoint.gateway : k => v.id },
    { for k, v in aws_vpc_endpoint.interface : k => v.id },
  )
}

output "flow_log_bucket" {
  value = try(aws_s3_bucket.flow_logs[0].bucket, null)
}
