# aws-vpc

Terraform for the roboshop VPC in `us-east-1`. It creates a multi-AZ, four-tier network ready for EKS, optionally peered with the default VPC where Jenkins runs.

Architecture diagram: [`docs/aws-vpc-architecture.drawio`](docs/aws-vpc-architecture.drawio). Open it in [app.diagrams.net](https://app.diagrams.net) or the draw.io VS Code extension.

## What it builds

| Component | Details |
|---|---|
| VPC | /16, DNS support and hostnames on, optional Amazon-provided /56 IPv6 |
| Public subnets | /24 per AZ, for NAT gateways and load balancers. `kubernetes.io/role/elb` tag. No auto-assigned public IPs |
| Private subnets | /20 per AZ, for apps and EKS nodes/pods. Egress through NAT. `kubernetes.io/role/internal-elb` tag |
| Data subnets | /24 per AZ, for RDS/ElastiCache/DocumentDB. No internet route; NACL allows only VPC and peer CIDRs |
| Intra subnets | /24 per AZ, for EKS control-plane ENIs and other things that never leave the VPC |
| NAT | One per AZ (prod) or one shared NAT gateway (`single_nat_gateway = true`, dev) |
| Endpoints | S3 and DynamoDB gateway endpoints (free) are always created. Interface endpoints are opt-in via `interface_endpoints` |
| Peering | Optional, to the default VPC or `peer_vpc_id`. Routes on both sides, cross-VPC DNS resolution, and a CIDR overlap check that fails the plan |
| Flow Logs | All traffic, 60s aggregation, Parquet in a dedicated encrypted, TLS-only S3 bucket with expiry |
| Guardrails | Default security group stripped of all rules; default NACL adopted so drift shows in plans |

## Subnet plan (/16)

| Tier | Size | Range (third octet) | Usable IPs per AZ |
|---|---|---|---|
| public | /24 | 0-3 | 251 |
| data | /24 | 10-13 | 251 |
| intra | /24 | 20-23 | 251 |
| private | /20 | 32-95 | 4,091 |
| spare | | 96-255 | |

Each tier has its own fixed range, so adding an AZ (up to 4) never collides with another tier. AZs are set by **AZ ID** (`use1-az1`), which maps to the same physical zone in every account. AZ names do not. `use1-az3` is avoided because it is capacity-constrained.

## Usage

```bash
terraform init -backend-config=backend/dev.hcl
terraform plan  -var-file=vars/dev.tfvars -out=planfile
terraform apply planfile
```

Each environment has its own state file (`backend/<env>.hcl`). State is encrypted and uses native S3 locking (`use_lockfile`), which needs Terraform >= 1.10.

| Env | AZs | NAT | Interface endpoints | Flow log retention |
|---|---|---|---|---|
| dev | 2 | 1 shared | none | 30 days |
| prod | 3 | 1 per AZ | ecr.api, ecr.dkr, sts, logs, ec2, elasticloadbalancing | 365 days |

## Tests

`tests/plan.tftest.hcl` uses a mocked AWS provider, so it needs no credentials. It checks NAT counts, peering routes, that no subnet auto-assigns public IPs, that the tier CIDRs never overlap with 4 AZs, and that an overlapping peer CIDR is rejected.

```bash
terraform init -backend=false && terraform test
```

## CI (Jenkinsfile)

`init` → `fmt -check` / `validate` / `tflint` / `checkov` → `plan` (archived as `plan.txt`) → manual approval → `apply` of the saved plan. Credentials come from the agent's IAM role, optionally assuming `DEPLOY_ROLE_ARN`. There are no static access keys. The agent needs the `terraform` label and `terraform`, `tflint` and `checkov` installed.

## Migrating from the previous version

Subnets, route tables and NAT gateways are **replaced** by this version: new CIDRs, AZ IDs, and `map_public_ip_on_launch = false`. Anything running in the old VPC must be moved or recreated, so run it in a maintenance window or build the new VPC alongside the old one. The state key also changed (`terraform/vpc.tfstate` → `terraform/vpc/<env>.tfstate`). To keep the old state instead, set `key` in `backend/dev.hcl` back to `terraform/vpc.tfstate`.

After the first `terraform init`, commit `.terraform.lock.hcl`.
