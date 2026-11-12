environment = "dev"
userid      = "JDHARMAPURI"
vpc_cidr    = "10.0.0.0/16"
azs         = ["use1-az1", "use1-az2"]

# Non-prod: one shared NAT gateway (saves ~$32/month per extra AZ).
single_nat_gateway = true

# Peer with the default VPC (where Jenkins/tooling runs).
enable_peering = true

# Interface endpoints cost ~$7.30/month per AZ each; off in dev.
interface_endpoints = []

flow_log_retention_days = 30
