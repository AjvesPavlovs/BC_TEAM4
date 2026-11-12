# Phase 3 — AWS setup guide (Windows / beginner)

## IMPORTANT — stop before spending money

**No AWS resources have been created by this ZIP.** The Terraform files are a new,
separate configuration in `infrastructure/`. The old `main.tf` and scripts are
**reference-only** under `legacy/`. Their old state is not included, and must not
be mixed with the new state.

**Do not run `terraform apply`, `terraform destroy` or `terraform init -migrate-state`
yet.** We will review the first plan together, check whether your bootcamp AWS
account permits creating IAM and RDS, and confirm use of existing resources.

## 1. Unpack and prepare

1. Extract `slice_sip_phase3_infrastructure.zip` into a new folder, e.g.
   `Documents\SliceAndSip-Phase3`. Keep your Phase 2 ZIP as a backup.
2. Open the extracted folder in **VS Code** (File → Open Folder).
3. Open **Terminal → New Terminal**, select **PowerShell**.
4. Do **not** copy any old `.tfstate` files or `terraform.tfvars` from the previous
   project into this new folder.

## 2. Check your AWS account and costs

1. Sign in to the AWS Console for your **bootcamp account**.
2. In the top-right, confirm the region is **Europe (Ireland) — eu-west-1**.
3. Open **Billing and Cost Management → Budgets → Create budget**. Set a cost
   warning threshold you are comfortable with. **An AWS Budget sends warnings;
   it is not a hard spending cap.** Ask your instructor about AWS credits.
4. Check the EC2 console for any *existing* Slice & Sip instances; don't delete
   them until we inspect the old Terraform state and determine ownership.
5. The full design can incur charges for the existing EC2 instance, EBS, public IPv4, RDS,
   ALB, ECS Fargate, CloudWatch, Secrets Manager, ECR, and potentially data transfer.
   The updated initial foundation plan does NOT create a new EC2 instance; it looks up the existing instructor-provided host.

For official estimates use [AWS Pricing Calculator](https://calculator.aws/).

## 3. Install local tools (one-time)

Install:

- [Terraform CLI](https://developer.hashicorp.com/terraform/install)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [VS Code](https://code.visualstudio.com/)

Close/reopen PowerShell after installing, then type:

```powershell
terraform version
aws --version
```

Both commands must print versions. Installing Docker Desktop on Windows is not
necessary to **inspect Terraform**; the Docker build will be done by Woodpecker
on EC2 once it is configured.

## 4. Configure AWS credentials privately

Use whichever authentication method your instructor provides. For IAM Identity
Center / AWS SSO, follow the AWS CLI guide and run:

```powershell
aws configure sso
aws sso login
```

For a permitted IAM CLI profile with access keys, follow your bootcamp's
instructions for `aws configure`. Never paste access keys into messages, screenshots,
Terraform variables, or Git.

Verify the CLI can access your account:

```powershell
aws sts get-caller-identity
aws configure get region
```

The first command prints the current account and principal. **Do not share the
unredacted output publicly.** The target region for this project is `eu-west-1`.
Your credentials must have permission to read and eventually create VPC, IAM,
EC2, ECR, ECS, CodeDeploy, RDS, ELB, SQS, CloudWatch, EventBridge and Secrets
Manager resources. Some bootcamp accounts restrict IAM creation; in that case
we will adapt Terraform before applying.

## 5. Prepare the variables (no AWS changes)

From the extracted project's root folder:

```powershell
Copy-Item .\infrastructure\terraform.tfvars.example .\infrastructure\terraform.tfvars
Set-Location .\infrastructure
```

Open `terraform.tfvars` in VS Code and **leave these values unchanged**:

```hcl
aws_region         = "eu-west-1"
project_name       = "slice-sip"
existing_ci_instance_id = "i-0eb789ac23be694c0"
enable_database    = false
enable_application = false
```

These variables contain no passwords. The `.tfvars` file is gitignored anyway.

## 6. Format, initialize, validate, plan (no resources created)

Run these in the `infrastructure` folder:

```powershell
terraform fmt -recursive
terraform init
terraform validate
terraform plan
```

What they do:

- `fmt`: reformat HCL files locally.
- `init`: download the AWS provider into your local `.terraform` directory.
- `validate`: check Terraform syntax and provider schemas.
- `plan`: read AWS metadata and show proposed resource changes. **It does not
  create resources** unless a provider has an unusual side effect; AWS Terraform
  providers generally use read APIs for the plan.

**STOP HERE.** Do not type `terraform apply` until we have reviewed the plan,
charges, IAM permissions, and the old account resources.

### What to send me

Send only:

1. The Terraform validation summary (`Success!` or any error text).
2. The final `Plan: ... to add, ... to change, ... to destroy` line.
3. Any errors, **redacting** account IDs, private domains, credentials, secret
   values and personal data. Do **not** upload `.tfstate`, `.tfplan`, real
   `.tfvars`, or webhook URLs.

## 7. Later stages (do not do these yet)

When we have reviewed your first plan:

1. **Foundation apply:** VPC, EC2 CI host, ECR, SQS/DLQ, four empty secret records,
   EventBridge, IAM, ECS cluster, CloudWatch. EC2/EIP and secrets can incur charges.
2. **Woodpecker + Ansible:** Install and configure via SSM and Ansible on the CI EC2.
   GitHub OAuth requires a public HTTPS CI hostname and valid callback URL.
3. **Initial images:** Build and push frontend/backend to ECR with immutable tags.
4. **Database:** change `enable_database = true` to provision private RDS. Its
   master credentials are generated and stored by RDS in AWS Secrets Manager.
5. **Discord:** insert each real webhook URL in its matching Secrets Manager
   secret using the Console (not Terraform). Rotate any previously exposed URL.
6. **Application:** set `enable_application = true`, and set the two image tags to
   pre-pushed tags; apply after checking the plan. This creates chargeable ALB
   and Fargate resources and the ECS CodeDeploy deployment group.
7. **CI/CD:** connect GitHub → Woodpecker → tests → ECR → Ansible → CodeDeploy.
   Use health checks and rollback to demonstrate blue/green.
8. **State:** Bootstrap an encrypted, versioned S3 backend (with lockfile and
   optional DynamoDB if required by the instructor), and migrate ONLY the new
   `infrastructure/` state using the documented procedure. Do not migrate the
   unrelated previous Terraform state into this project.

## 8. Security notes and tradeoffs

- CI EC2: SSH port 22 is closed. We will administer it via AWS Systems Manager
  Session Manager. Ubuntu 22.04 AMIs usually include SSM Agent; verify status.
- CI HTTPS: ports 80/443 are intended for a reverse proxy (Phase 4). Woodpecker
  UI and GitHub webhook must be accessible securely over HTTPS for OAuth.
- App Fargate: tasks run in **public** subnets with public IP for outbound AWS
  API access without a NAT gateway. Security groups limit inbound web traffic
  to the ALB. **This is a cost-conscious bootcamp tradeoff**, not a recommended
  production network architecture. The RDS database is in private subnets.
- Real customer details: do not collect actual payment-card information or
  personal customer addresses; the initial demo app may be HTTP if there is no
  ACM certificate. Before public usage, configure HTTPS and appropriate abuse
  controls (rate limiting, validation and authentication where needed).
- Secrets: only Terraform secret *metadata* is created. Actual webhook values
  are added directly in Secrets Manager. RDS manages its own master password.
- IAM: CI deployment permissions for ECS/CodeDeploy still contain selected
  wildcards; narrow them before using an untrusted repository. Woodpecker
  pipelines have powerful Docker-host access. Enable only trusted repositories.
- Database: the demo configuration sets `skip_final_snapshot = true`; deleting
  RDS later may permanently destroy tickets and orders. Take a snapshot if needed.
- Blue/green minimizes planned application interruptions but does not remove the
  single-region ALB and other possible infrastructure failures.
- Repeated SQS delivery can generate repeated Discord messages after partial
  failures. The current system is *at least once*, not exactly once.

## 9. If validation fails

Copy the error message (without secret values) and stop. Do not guess, run
`terraform apply`, or change IAM permissions blindly. We'll fix the relevant
module together.


## Existing CI server reuse (Phase 3 revision)

The bootcamp CI instance is `i-0eb789ac23be694c0` in `eu-west-1`.
This project **reads** that EC2 via a Terraform data source. We do not import it
or take over its lifecycle. The security group and instance profile remain
controlled by the bootcamp. See `EXISTING_CI_EC2_CHECKLIST.md` for the next
checks and instructions. Do NOT apply yet.
