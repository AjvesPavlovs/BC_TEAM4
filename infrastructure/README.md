# Target AWS infrastructure (Phase 3 draft)

Use `../docs/PHASE3_AWS_BEGINNER_GUIDE.md` before running Terraform.

## Module files

- `versions.tf` — AWS provider and availability zone lookup (new standalone state root)
- `variables.tf` — existing EC2 lookup ID, staged feature switches and immutable image tags
- `network.tf` — isolated VPC, two AZs, public Fargate/ALB and private RDS subnets
- `ci.tf` — read-only reference to existing bootcamp EC2 for Woodpecker/Ansible ONLY
- `iam.tf` — ECS task roles and CodeDeploy role; existing EC2 instance profile is untouched
- `registry.tf` — two immutable-tag ECR repositories
- `queues.tf` — encrypted SQS, DLQ and CloudWatch→EventBridge→SQS
- `secrets.tf` — four empty Discord Secrets Manager secrets (never URL values)
- `database.tf` — optional private RDS PostgreSQL with AWS-managed password
- `ecs.tf` — optional app and notification Fargate services
- `deployment.tf` — optional ALB, blue/green target groups and CodeDeploy group
- `monitoring.tf` — CI, application, DB and DLQ CloudWatch alarms
- `outputs.tf` — non-sensitive setup identifiers and URLs

## Safe initial review

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform plan
```

**DO NOT APPLY YET.** See guide. The first plan now REFERENCES the existing EC2 without creating a new host. It is not a complete running app;
it intentionally does not provision ALB, RDS or Fargate until images, CI and
costs are reviewed.

## State boundary

Do not reuse Terraform state from the legacy root. This is a NEW Terraform state,
not a renamed resource-only refactor. We will audit existing infrastructure and
later move this new root's state to encrypted/versioned S3. Mixing the old and new
states could cause accidental destructive operations.

## Note on deployment ownership

After bootstrap, CodeDeploy owns production app task revisions. Terraform ignores
external changes to the app service task definition so plans do not undo
successful CI deployments. Worker deployments are rolling and will require
coordination with backend image updates.

## Instructor-provided CI instance

`existing_ci_instance_id` is an existing EC2 data source in the bootcamp VPC.
Terraform does **not** manage its EC2 lifecycle, IAM instance profile, security
group, or public IP. The app VPC is separate; the CI host reaches deployment
services via AWS APIs. The CI host must have suitable outbound access and
its *existing* role needs ECR / ECS / deployment permissions approved by the
instructor. Refer to `../docs/EXISTING_CI_EC2_CHECKLIST.md`.
