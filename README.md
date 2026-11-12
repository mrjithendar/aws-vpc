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

## Deploying with GitHub Actions

`.github/workflows/deploy.yml` (plus the reusable `terraform-env.yml`):

| Trigger | What runs |
|---|---|
| Pull request to `master` | Static checks (fmt, validate, `terraform test`, tflint, checkov), then plans for **dev** and **prod**. Each plan is posted as a PR comment that is updated in place on later pushes |
| Push / merge to `master` | Checks → plan dev → **apply dev** → plan prod → **apply prod** (prod waits for an approval) |
| Manual (`workflow_dispatch`) | Plans the chosen environment; applies it if `apply` is ticked |

How it works:
- **No AWS keys.** Jobs use GitHub OIDC. Plans assume a read-only role. Applies assume a deploy role whose trust policy only accepts jobs running in the `dev` or `prod` GitHub environment.
- **The apply uses exactly the reviewed plan.** The plan job uploads the `planfile` and lock file as an artifact, and the apply job applies that file. If state changed in between, Terraform stops with "Saved plan is stale" instead of applying something nobody reviewed.
- The apply is skipped when the plan has no changes (`-detailed-exitcode`).
- Applies are serialized per environment, and an apply in progress is never cancelled. PR runs cancel superseded runs.
- Changes that only touch `docs/`, `*.md` or the `Jenkinsfile` don't trigger the workflow.

### One-time setup

1. **Create the IAM roles** with admin credentials, from a workstation:
   ```bash
   cd bootstrap/github-oidc
   terraform init && terraform apply
   # If the account already has the GitHub OIDC provider: -var create_oidc_provider=false
   ```
2. **Repository variables** (Settings → Secrets and variables → Actions → Variables):
   - `AWS_PLAN_ROLE_ARN`: the `plan_role_arn` output
   - `AWS_REGION`: `us-east-1` (optional; this is the default)
3. **Environments** (Settings → Environments). Create `dev` and `prod` and give each a variable `AWS_ROLE_ARN` set to the `apply_role_arn` output. On **prod**, add **Required reviewers** and limit deployment branches to `master`.
4. **Branch protection** on `master`: require the `Static checks` and plan jobs to pass.

The apply role has `AmazonVPCFullAccess`, rights on the flow-log bucket and log delivery, and access to the state prefix. The plan role has `ReadOnlyAccess` plus write access to the state prefix, which the S3 lock file needs.

## CI with Jenkins (alternative)

`Jenkinsfile`: `init` → `fmt -check` / `validate` / `tflint` / `checkov` → `plan` (archived as `plan.txt`) → manual approval → `apply` of the saved plan. Credentials come from the agent's IAM role, optionally assuming `DEPLOY_ROLE_ARN`. There are no static access keys. The agent needs the `terraform` label and `terraform`, `tflint` and `checkov` installed. Use one pipeline or the other, not both, so two systems never apply the same state.

## Migrating from the previous version

Subnets, route tables and NAT gateways are **replaced** by this version: new CIDRs, AZ IDs, and `map_public_ip_on_launch = false`. Anything running in the old VPC must be moved or recreated, so run it in a maintenance window or build the new VPC alongside the old one. The state key also changed (`terraform/vpc.tfstate` → `terraform/vpc/<env>.tfstate`). To keep the old state instead, set `key` in `backend/dev.hcl` back to `terraform/vpc.tfstate`.

After the first `terraform init`, commit `.terraform.lock.hcl`.
