terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

resource "aws_security_group" "alb" {
  name        = "slice-sip-fargate-alb-sg"
  description = "Allow public HTTP traffic to the Slice and Sip load balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "slice-sip-fargate-alb-sg"
  }
}

resource "aws_security_group" "task" {
  name        = "slice-sip-fargate-task-sg"
  description = "Allow HTTP from the load balancer to the Fargate task"
  vpc_id      = data.aws_vpc.default.id

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
    Name = "slice-sip-fargate-task-sg"
  }
}

resource "aws_lb" "slice_sip" {
  name               = "slice-sip-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids

  tags = {
    Name = "slice-sip-alb"
  }
}

resource "aws_lb_target_group" "slice_sip" {
  name        = "slice-sip-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = {
    Name = "slice-sip-tg"
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
  name = "slice-sip-cluster"
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "slice-sip-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "slice_sip" {
  name              = "/ecs/slice-sip"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "slice_sip" {
  family                   = "slice-sip"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "slice-sip"
      image     = "aivisp/slice.sip.app.v1.0:latest"
      essential = true

      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.slice_sip.name
          "awslogs-region"        = "eu-west-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution]
}

resource "aws_ecs_service" "slice_sip" {
  name            = "slice-sip-service"
  cluster         = aws_ecs_cluster.slice_sip.id
  task_definition = aws_ecs_task_definition.slice_sip.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.public.ids
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