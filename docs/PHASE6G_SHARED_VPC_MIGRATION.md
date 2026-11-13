# Phase 6G – Bootcamp shared VPC migration (review-only)

No AWS resources are created or modified by applying this source patch. **Do not run `terraform apply` yet.** The Terraform plan is still blocked by the explicitly denied IAM role creation and possibly by SQS / Logs / EventBridge permissions. The instructor must approve use of the shared bootcamp VPC and subnets before deploying.

## Intended shared network

- Existing VPC `vpc-04b6091923e283784` (eu-west-1, 172.31.0.0/16)
- ALB public eu-west-1a `subnet-09499899162c048f7`, eu-west-1b `subnet-0085786c1374a372c` — inherit IGW route from main route table
- ECS private/NAT eu-west-1a `subnet-0d967012a16e6162`, eu-west-1b `subnet-044a7aac53c2aa425` — NAT gateway `nat-0aec9565db67180f9` (single-AZ NAT availability trade-off)
- RDS isolated eu-west-1a `subnet-0f680f23bd1732c26`, eu-west-1b `subnet-0ffb7e6df0653fa22` — no internet default route

Existing AWS routing resources, NAT, VPC and subnets are *only referenced*; not imported as managed resources and not modified. New security groups remain managed by this project.

## Before validation

1. Run `git status -sb` in your local repository and ensure you're on `devops/woodpecker-fargate`. Keep a backup or commit any unrelated local edits first.
2. Preview patch using `git apply --check path/to/phase6g_shared_vpc.patch`.
3. Apply with `git apply path/to/phase6g_shared_vpc.patch`, then inspect with `git diff --check` and `git diff`.
4. Append the four `existing_vpc_id` / `*_subnet_ids` assignments from `infrastructure/terraform.tfvars.example` to your **local ignored** `infrastructure/terraform.tfvars` without duplicating keys. **Never commit tfvars**.
5. From `infrastructure/`, run `terraform fmt network.tf variables.tf deployment.tf database.tf ecs.tf` and `terraform validate`.
6. Run a fresh **plan only** with existing application/database flags and immutable image tags; verify `aws_vpc.main`, `aws_subnet.public`, `aws_subnet.database`, `aws_internet_gateway.main`, `aws_route_table.public`, and `aws_route_table_association.public` are NOT present.
7. Expected plan, if nothing else changed: approximately **47 to add, 0 to change, 0 to destroy** (9 network resources removed from prior 56). The exact result must be confirmed locally; there may be blocking IAM and other actions.

Don't use the older `phase6-initial-v2.tfplan` after source changes. Keep ECS deployment automation unmodified until the IAM approvals and initial healthy service exist.
