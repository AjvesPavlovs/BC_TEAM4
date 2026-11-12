# This ALB is chargeable. It is only created once enable_application = true.
resource "aws_lb" "app" {
  count              = var.enable_application ? 1 : 0
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  enable_deletion_protection = false # Demo teardown
}

resource "aws_lb_target_group" "blue" {
  count                = var.enable_application ? 1 : 0
  name                 = "${var.project_name}-blue"
  vpc_id               = aws_vpc.main.id
  protocol             = "HTTP"
  port                 = 80
  target_type          = "ip"
  deregistration_delay = 30
  health_check {
    enabled             = true
    path                = "/ready"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "green" {
  count                = var.enable_application ? 1 : 0
  name                 = "${var.project_name}-green"
  vpc_id               = aws_vpc.main.id
  protocol             = "HTTP"
  port                 = 80
  target_type          = "ip"
  deregistration_delay = 30
  health_check {
    enabled             = true
    path                = "/ready"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP is okay ONLY for synthetic testing. Configure ACM for HTTPS before a
# public demonstration with genuine user-provided data.
resource "aws_lb_listener" "http" {
  count             = var.enable_application ? 1 : 0
  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.enable_https ? "redirect" : "forward"
    dynamic "redirect" {
      for_each = local.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    dynamic "forward" {
      for_each = local.enable_https ? [] : [1]
      content {
        target_group { arn = aws_lb_target_group.blue[0].arn }
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_application && local.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.app[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.app_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue[0].arn
  }
}

resource "aws_codedeploy_app" "app" {
  count            = var.enable_application ? 1 : 0
  name             = "${var.project_name}-ecs"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "app" {
  count                  = var.enable_application ? 1 : 0
  app_name               = aws_codedeploy_app.app[0].name
  deployment_group_name  = "${var.project_name}-blue-green"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.app[0].name
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_REQUEST"]
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [local.enable_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn]
      }
      target_group { name = aws_lb_target_group.blue[0].name }
      target_group { name = aws_lb_target_group.green[0].name }
    }
  }
  depends_on = [aws_iam_role_policy_attachment.codedeploy]
}
