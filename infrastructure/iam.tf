locals {
  ecs_tasks_trust = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  rds_secret_arns = var.enable_database ? [aws_db_instance.postgres[0].master_user_secret[0].secret_arn] : []
}

# The existing bootcamp instance profile is instructor-managed.
# Do NOT automatically create or attach an alternate instance profile here.
# See docs/EXISTING_CI_EC2_CHECKLIST.md for the precise permissions to request.

resource "aws_iam_role" "task_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_app" {
  name               = "${var.project_name}-app-task"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "app_database" {
  count = var.enable_database ? 1 : 0
  name  = "read-rds-managed-secret"
  role  = aws_iam_role.task_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = local.rds_secret_arns
    }]
  })
}

resource "aws_iam_role" "task_notifications" {
  name               = "${var.project_name}-notifications-task"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "notifications" {
  name = "read-discord-and-rds-secrets-sqs"
  role = aws_iam_role.task_notifications.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = concat(local.rds_secret_arns, [for secret in aws_secretsmanager_secret.discord : secret.arn])
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.discord.arn
      }
    ]
  })
}

# Native ECS blue/green assumes this role to update ALB listener rules and
# target groups. It is NOT attached to the instructor-managed CI EC2 instance.
resource "aws_iam_role" "ecs_infrastructure" {
  count = var.enable_application ? 1 : 0
  name  = "${var.project_name}-ecs-load-balancer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  count      = var.enable_application ? 1 : 0
  role       = aws_iam_role.ecs_infrastructure[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
