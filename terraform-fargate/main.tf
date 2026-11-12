terraform {
  required_version = ">= 1.10.0"
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}

data "aws_subnet" "public" {
  for_each = var.public_subnet_ids
  id       = each.value
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Allow public HTTP traffic to the Slice and Sip load balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-task-sg"
  description = "Allow HTTP from the load balancer to the Fargate task"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-task-sg"
  }
}

resource "aws_lb" "slice_sip" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  lifecycle {
    precondition {
      condition = (
        alltrue([for subnet in data.aws_subnet.public : subnet.vpc_id == var.vpc_id]) &&
        length(toset([for subnet in data.aws_subnet.public : subnet.availability_zone])) == length(var.public_subnet_ids)
      )
      error_message = "Specify subnets from the selected VPC, with one subnet per Availability Zone."
    }
  }

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "slice_sip" {
  name        = "${var.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.slice_sip.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.slice_sip.arn
  }
}

resource "aws_ecs_cluster" "slice_sip" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "slice_sip" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "slice_sip" {
  family                   = var.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.task_execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "slice-sip"
      image     = var.application_image
      essential = true

      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.slice_sip.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

}

resource "aws_ecs_service" "slice_sip" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.slice_sip.id
  task_definition = aws_ecs_task_definition.slice_sip.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.slice_sip.arn
    container_name   = "slice-sip"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http]
}

output "application_url" {
  description = "Public URL for the Slice and Sip application"
  value       = "http://${aws_lb.slice_sip.dns_name}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.slice_sip.name
}

output "ecs_service_name" {
  value = aws_ecs_service.slice_sip.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.slice_sip.arn
}
