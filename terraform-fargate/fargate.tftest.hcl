mock_provider "aws" {}

variables {
  aws_account_id          = "123456789012"
  vpc_id                  = "vpc-0123456789abcdef0"
  public_subnet_ids       = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  alb_ingress_cidrs       = ["203.0.113.10/32"]
  task_execution_role_arn = "arn:aws:iam::123456789012:role/ecs-task-execution"
  application_image       = "example/slice-sip@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

override_data {
  target = data.aws_subnet.public["subnet-0123456789abcdef0"]
  values = {
    vpc_id            = "vpc-0123456789abcdef0"
    availability_zone = "eu-west-1a"
  }
}

override_data {
  target = data.aws_subnet.public["subnet-0123456789abcdef1"]
  values = {
    vpc_id            = "vpc-0123456789abcdef0"
    availability_zone = "eu-west-1b"
  }
}

run "plans_fargate_release" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.alb_to_task.ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.alb_to_task.from_port == 80 && aws_vpc_security_group_egress_rule.alb_to_task.to_port == 80
    error_message = "The ALB must allow outbound TCP port 80 to the application tasks."
  }

  assert {
    condition     = aws_ecs_service.slice_sip.launch_type == "FARGATE" && aws_ecs_service.slice_sip.deployment_circuit_breaker[0].rollback
    error_message = "The application must use Fargate with rollback enabled."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.slice_sip.container_definitions)[0].image == var.application_image
    error_message = "The task definition must run the supplied image digest."
  }

  assert {
    condition     = aws_lb_target_group.slice_sip.target_type == "ip" && aws_lb_target_group.slice_sip.health_check[0].path == "/"
    error_message = "The ALB must check the application root on the Fargate IP targets."
  }

  assert {
    condition     = aws_ecs_task_definition.slice_sip.execution_role_arn == var.task_execution_role_arn && length(aws_cloudwatch_log_group.slice_sip) == 1 && jsondecode(aws_ecs_task_definition.slice_sip.container_definitions)[0].logConfiguration.logDriver == "awslogs"
    error_message = "A supplied execution role must enable CloudWatch container logs."
  }
}

run "plans_public_image_without_execution_role" {
  command = plan

  variables {
    task_execution_role_arn = null
  }

  assert {
    condition     = aws_ecs_task_definition.slice_sip.execution_role_arn == null && length(aws_cloudwatch_log_group.slice_sip) == 0 && try(jsondecode(aws_ecs_task_definition.slice_sip.container_definitions)[0].logConfiguration, null) == null
    error_message = "The public-image configuration must omit the execution role and CloudWatch logging."
  }
}

run "rejects_mutable_image_tag" {
  command = plan

  variables {
    application_image = "example/slice-sip:latest"
  }

  expect_failures = [var.application_image]
}

run "rejects_subnets_in_same_availability_zone" {
  command = plan

  override_data {
    target = data.aws_subnet.public["subnet-0123456789abcdef1"]
    values = {
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "eu-west-1a"
    }
  }

  expect_failures = [aws_lb.slice_sip]
}
