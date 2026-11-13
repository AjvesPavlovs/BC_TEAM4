# Instructor-managed ECS roles only. Terraform does not create roles or attach
# IAM policies in this project. The bootcamp CI instance profile is untouched.
# This read-only data lookup verifies the existing task execution role exists.
data "aws_iam_role" "task_execution" {
  count = var.enable_application ? 1 : 0
  name  = var.existing_ecs_execution_role_name
}

# The following ARNs are passed in from local terraform.tfvars only after the
# instructor creates and configures the three project-specific roles:
#   var.app_task_role_arn, var.notifications_task_role_arn,
#   var.ecs_infrastructure_role_arn
# Required trust and least-privilege policies: docs/PHASE6K_IAM_ROLE_HANDOFF.md
