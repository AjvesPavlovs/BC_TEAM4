resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-ecs"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}/app"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "notifications" {
  name              = "/ecs/${var.project_name}/notifications"
  retention_in_days = 7
}

# NGINX + API are in one task: NGINX accesses API on 127.0.0.1:8000.
resource "aws_ecs_task_definition" "app" {
  count                    = var.enable_application ? 1 : 0
  family                   = "${var.project_name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_app.arn

  lifecycle {
    precondition {
      condition = var.enable_database && trimspace(var.frontend_image_tag) != "" && trimspace(var.backend_image_tag) != ""
      error_message = "Enable database and provide pre-pushed frontend_image_tag and backend_image_tag before creating ECS application services."
    }
  }

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      command   = ["sh", "-c", "python migrate.py && exec uvicorn app:app --host 0.0.0.0 --port 8000"]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "RDS_SECRET_ARN", value = aws_db_instance.postgres[0].master_user_secret[0].secret_arn },
        { name = "RDS_HOST", value = aws_db_instance.postgres[0].address },
        { name = "RDS_PORT", value = "5432" },
        { name = "RDS_DATABASE", value = "slicesip" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    },
    {
      name         = "frontend"
      image        = "${aws_ecr_repository.frontend.repository_url}:${var.frontend_image_tag}"
      essential    = true
      portMappings = [{ containerPort = 80, protocol = "tcp" }]
      environment  = [{ name = "BACKEND_HOST", value = "127.0.0.1:8000" }]
      dependsOn    = [{ containerName = "backend", condition = "START" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "frontend"
        }
      }
    }
  ])
}

# Separately scaled queue worker task (not behind ALB).
resource "aws_ecs_task_definition" "notifications" {
  count                    = var.enable_application ? 1 : 0
  family                   = "${var.project_name}-notifications"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_notifications.arn

  container_definitions = jsonencode([
    for role in ["outbox", "discord"] : {
      name      = role
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      command   = ["python", role == "outbox" ? "outbox_publisher.py" : "notification_worker.py"]
      essential = true
      environment = concat([
        { name = "AWS_REGION", value = var.aws_region },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.discord.id }
      ], role == "outbox" ? [
        { name = "RDS_SECRET_ARN", value = aws_db_instance.postgres[0].master_user_secret[0].secret_arn },
        { name = "RDS_HOST", value = aws_db_instance.postgres[0].address },
        { name = "RDS_PORT", value = "5432" },
        { name = "RDS_DATABASE", value = "slicesip" }
      ] : [
        for channel in sort(tolist(local.discord_channels)) : {
          name  = "DISCORD_${upper(channel)}_SECRET_ID"
          value = aws_secretsmanager_secret.discord[channel].name
        }
      ])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.notifications.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = role
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  count           = var.enable_application ? 1 : 0
  name            = "${var.project_name}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_controller { type = "CODE_DEPLOY" }
  health_check_grace_period_seconds = 120
  network_configuration {
    subnets          = aws_subnet.public[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.app.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.blue[0].arn
    container_name   = "frontend"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
  lifecycle {
    # After bootstrap, CodeDeploy (invoked by Ansible) owns running revisions.
    ignore_changes = [task_definition, load_balancer]
  }
}

resource "aws_ecs_service" "notifications" {
  count           = var.enable_application ? 1 : 0
  name            = "${var.project_name}-notifications"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.notifications[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.notifications.id]
  }
  # Worker updates are rolling: they do not serve customer HTTP traffic.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
