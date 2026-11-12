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

## CI/CD: GitHub Actions, GitLab CI and Jenkins

All three pipelines share the same design, so you can use any of them, or run more than one:

| | GitHub Actions | GitLab CI | Jenkins |
|---|---|---|---|
| File | `.github/workflows/deploy.yml` + `terraform-env.yml` | `.gitlab-ci.yml` | `Jenkinsfile` (Multibranch) |
| Checks | fmt, validate, `terraform test`, tflint, checkov | same | same, each in a pinned container |
| PR / MR | plan dev + prod, posted as a PR comment | plan dev + prod, shown in the MR Terraform widget | plan dev + prod, archived as `plan-<env>.txt` |
| Merge to `master` | apply dev → prod after environment approval | apply dev → prod as a manual job | apply dev → prod after `input` approval |
| Nightly | drift check (job fails on drift) | drift check, if you add a pipeline schedule (job warns on drift) | drift check (build UNSTABLE on drift) |
| Manual | `workflow_dispatch` (env, apply) | Run pipeline (`TF_ENV`, `APPLY`) | Build with Parameters (`ENV`, `APPLY`) |
| AWS auth | GitHub OIDC | GitLab OIDC ID token | agent instance role → `sts:AssumeRole` |

What all three share:
- **No static AWS keys.** Plans use a read-only role and applies use a deploy role. Both come from `bootstrap/ci-roles`.
- **The apply uses exactly the reviewed plan.** The saved `planfile` and lock file are passed from the plan step to the apply step. If state changed in between, Terraform stops with "Saved plan is stale" instead of applying something nobody reviewed.
- The apply is skipped when a plan has no changes. Applies are serialized per environment and never cancelled mid-way.

### Only one system auto-applies

**`AWS_VPC_DEPLOYER` = `github` (default) | `gitlab` | `jenkins`** picks which pipeline auto-applies on merges to `master`. Set the same value everywhere: GitHub repo variable, GitLab CI/CD variable, and Jenkins global or folder env var. The other systems still run checks, plans and drift detection on `master` but never apply automatically. A manual apply is possible from any of them, and the S3 state lock plus the stale-plan check keep simultaneous runs safe.

### One-time setup

1. **IAM roles.** Apply `bootstrap/ci-roles` with admin credentials. Turn on the systems you use:
   ```bash
   cd bootstrap/ci-roles
   terraform init
   terraform apply \
     -var enable_gitlab=true \
     -var 'jenkins_role_arns=["arn:aws:iam::<acct>:role/<jenkins-agent-role>"]'
   # Already have the GitHub or GitLab OIDC provider? Add -var create_github_oidc_provider=false / create_gitlab_oidc_provider=false
   ```
   This outputs `plan_role_arn` and `apply_role_arn`.
2. **GitHub Actions**
   - Repo variables: `AWS_PLAN_ROLE_ARN` (the plan role) and, optionally, `AWS_VPC_DEPLOYER`.
   - Create environments `dev` and `prod`, each with variable `AWS_ROLE_ARN` (the apply role). On **prod**, add required reviewers and allow deployments only from `master`.
3. **GitLab CI** (a project on gitlab.com or self-managed, either mirroring this repo or using *CI/CD for external repo*)
   - CI/CD variables: `AWS_VPC_PLAN_ROLE_ARN`, `AWS_VPC_APPLY_ROLE_ARN`, and `AWS_VPC_DEPLOYER=gitlab` if GitLab should deploy.
   - Make `master` a **protected branch**. The apply role only trusts `master`.
   - On Premium, also protect the `prod` environment with required approvals.
   - Add a nightly **pipeline schedule** on `master` for drift detection.
   - Set `gitlab_url` and `gitlab_project_path` in the bootstrap if they differ from the defaults.
4. **Jenkins**
   - Create a Multibranch Pipeline job for this repo, with agents labelled `docker` that have Docker installed.
   - Global or folder env vars: `AWS_VPC_PLAN_ROLE_ARN`, `AWS_VPC_APPLY_ROLE_ARN`, `AWS_VPC_DEPLOYER`, and `AWS_VPC_PROD_APPROVERS` (users or groups allowed to approve prod).
   - On EC2 agents, set the IMDSv2 hop limit to 2 so containers can use the instance role.
   - Plugins needed: Docker Pipeline, Timestamper and JUnit.
5. **Branch protection** on `master`: require the checks and plan jobs to pass.

Role permissions: the apply role has `AmazonVPCFullAccess`, rights on the flow-log bucket and log delivery, and the state prefix. The plan role has `ReadOnlyAccess` plus write access to the state prefix, which the S3 lock file needs.

## Migrating from the previous version

Subnets, route tables and NAT gateways are **replaced** by this version: new CIDRs, AZ IDs, and `map_public_ip_on_launch = false`. Anything running in the old VPC must be moved or recreated, so run it in a maintenance window or build the new VPC alongside the old one. The state key also changed (`terraform/vpc.tfstate` → `terraform/vpc/<env>.tfstate`). To keep the old state instead, set `key` in `backend/dev.hcl` back to `terraform/vpc.tfstate`.

After the first `terraform init`, commit `.terraform.lock.hcl`.
