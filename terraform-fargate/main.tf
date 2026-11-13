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

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  public_subnets_by_az = {
    for subnet in data.aws_subnet.public :
    subnet.availability_zone => subnet.id...
  }

  selected_public_subnet_ids = [
    for az in sort(keys(local.public_subnets_by_az)) :
    sort(local.public_subnets_by_az[az])[0]
  ]
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
  subnets            = local.selected_public_subnet_ids

  lifecycle {
    precondition {
      condition     = length(local.selected_public_subnet_ids) >= 2
      error_message = "ALB requires public subnets in at least two Availability Zones."
    }
  }

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

resource "aws_ecs_task_definition" "slice_sip" {
  family                   = "slice-sip"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "slice-sip"
      image     = "aivisp/slice.sip.app.v1.0:latest"
      essential = true

      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
    }
  ])
}

resource "aws_ecs_service" "slice_sip" {
  name            = "slice-sip-service"
  cluster         = aws_ecs_cluster.slice_sip.id
  task_definition = aws_ecs_task_definition.slice_sip.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.selected_public_subnet_ids
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