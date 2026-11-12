environment = "prod"
userid      = "JDHARMAPURI"
vpc_cidr    = "10.10.0.0/16"
azs         = ["use1-az1", "use1-az2", "use1-az4"]

# One NAT gateway per AZ: an AZ outage can't take out egress for the others.
single_nat_gateway = false

enable_peering = true

# Endpoints an EKS cluster with private nodes needs to pull images and get credentials
# without going through NAT.
interface_endpoints = [
  "ecr.api",
  "ecr.dkr",
  "sts",
  "logs",
  "ec2",
  "elasticloadbalancing",
]

eks_cluster_name        = "roboshop-prod"
flow_log_retention_days = 365
