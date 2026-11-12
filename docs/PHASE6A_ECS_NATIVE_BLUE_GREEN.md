# Slice & Sip — Phase 6A: native ECS blue/green Terraform review

**Status: configuration patch ONLY. Do not run `terraform apply` yet.**

This patch preserves the existing bootcamp EC2 instance (Woodpecker CI/Ansible) and the
already-provisioned ECR repositories. Application containers will run only on ECS Fargate.
It replaces the earlier CodeDeploy plan with ECS native blue/green. No AWS resource is
created by copying or committing this patch.

## What changed and why

| File | Change | Why |
|---|---|---|
| `infrastructure/ecs.tf` | ECS controller + `deployment_configuration { strategy = "BLUE_GREEN" }`; health rollback and ALB advanced config | ECS, not CodeDeploy, starts green tasks and shifts traffic |
| `infrastructure/deployment.tf` | Remove CodeDeploy app/group; add one ALB production listener rule with blue/green weighted target groups | ECS requires an ALB **listener rule ARN** and both target groups must be associated with listener routing |
| `infrastructure/iam.tf` | Replace CodeDeploy role with ECS load balancer infrastructure role, attaching the AWS managed policy | ECS must be allowed to modify listener weights and target-group registrations |
| `infrastructure/variables.tf` | Add `blue_green_bake_minutes` (default 5) | Keep the old revision briefly available after shifting traffic |
| `infrastructure/outputs.tf` | Replace CodeDeploy outputs with ECS service name and production rule ARN | Outputs reflect actual architecture |

## Important deployment behaviors

- Initial production listener rule sends **100%** to blue and **0%** to green. Both groups are
  associated with the rule. Thus ECS can use the production rule without an extra public test port.
- During deployment ECS controls the listener-rule **action** (target-group weights).
  The Terraform resource has `lifecycle { ignore_changes = [action] }` so subsequent plans
  don't undo a successful deployment. If you need to restore the original listener manually,
  investigate drift and ECS deployment state first; never blindly force the action.
- CI/Ansible will own **task-definition revisions** after initial bootstrap. Terraform ignores
  ECS service `task_definition` and `load_balancer` drift to avoid reverting CI deployments.
- `/ready` checks the PostgreSQL connection; therefore RDS and its IAM/database settings must
  be working before enabling the ECS application service.
- ECS service `deployment_circuit_breaker` requests rollback for unhealthy task startups.
  Rollback requires a previous successfully completed deployment. It does not make a single
  ALB or regional outage impossible, and database migrations must remain backward compatible.
- `enable_application` and `enable_database` remain **false** by default.
- The database, app ALB, ECS service and Fargate task run time have AWS charges when enabled.
  ECS blue/green temporarily runs both revisions during bake time.
- With no ACM certificate and owned DNS name, the application ALB initially serves **HTTP**.
  Only use **synthetic demo information**, not real customer or support data.
- Existing CodeDeploy resources were *not deployed*: the earlier Terraform configuration
  used `enable_application=false`. Check state/plan before acting if that changed.

## IAM considerations

The AWS-managed policy for the new role is:

`arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers`

Trust principal: `ecs.amazonaws.com`.

The identity that creates/updates the ECS service also needs permission to **pass** this role:
`iam:PassRole` for the specific infrastructure role, with `iam:PassedToService=ecs.amazonaws.com`.
The bootcamp account may deny creating/attaching roles or passing them; request only the
required permissions from the instructor rather than changing the existing EC2 instance profile.

Application task and execution roles also require their own `iam:PassRole` rights for ECS tasks,
and the Woodpecker/Ansible deployment caller will need `ecs:UpdateService` and
`ecs:RegisterTaskDefinition` plus read/status permissions. Those are later work.

## Apply patch on Windows (Git Bash / VS Code)

1. Keep the working repository and `devops/woodpecker-fargate` branch.
2. Unzip this patch to `~/Downloads/slice_sip_phase6a_native_blue_green_patch`.
3. From the **local** repository root:

   ```bash
   cd "$HOME/git-repo/new build/slice_sip_git"
   git status -sb
   cp -a "$HOME/Downloads/slice_sip_phase6a_native_blue_green_patch/." .
   git diff --check
   git diff --stat
   ```

4. Terraform checks (in the same local repository, using your MFA-authenticated AWS CLI):

   ```bash
   cd infrastructure
   terraform fmt ecs.tf deployment.tf iam.tf variables.tf outputs.tf
   terraform validate
   terraform plan
   ```

   If `terraform init` is requested, run it in this same existing infrastructure root.
   Do NOT make a new state directory: the existing local state already manages both ECR repos.

5. Check that the plan does **not** replace/destroy the two existing ECR repos or touch your
   instructor-managed EC2 instance. The current defaults may still plan other infrastructure
   resources; this is a **review only**. Do **not** run `terraform apply`.
6. After validating, inspect changes and stage only these six files for commit:

   ```bash
   cd ..
   git diff --check
   git status -sb
   git diff -- infrastructure/ecs.tf infrastructure/deployment.tf infrastructure/iam.tf infrastructure/variables.tf infrastructure/outputs.tf
   ```

   Share any `terraform validate`/`plan` errors or the final plan summary before committing.

## Subsequent phases (not implemented by this patch)

1. Reconcile remaining Terraform infrastructure and bootcamp IAM permissions.
2. Enable RDS and populate Secrets Manager Discord webhooks **without** putting values in Terraform.
3. Enable the initial ECS Fargate services using the already-published matching immutable image tags.
4. Add Ansible ECS task-definition registration and deployment-state verification.
5. Extend Woodpecker to deploy only after both image pushes succeed, wait for blue/green
   health checks, and verify browser change and rollback behavior.

Reference docs:
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb-resources-for-blue-green.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/troubleshooting-blue-green.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AmazonECSInfrastructureRolePolicyForLoadBalancers.html
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service
