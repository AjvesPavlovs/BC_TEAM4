# This ALB is chargeable. It is only created once enable_application = true.
resource "aws_lb" "app" {
  count                      = var.enable_application ? 1 : 0
  name                       = "${var.project_name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.alb_public_subnet_ids
  enable_deletion_protection = false # Demo teardown
}

resource "aws_lb_target_group" "blue" {
  count                = var.enable_application ? 1 : 0
  name                 = "${var.project_name}-blue"
  vpc_id               = data.aws_vpc.bootcamp.id
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
  vpc_id               = data.aws_vpc.bootcamp.id
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

# HTTP is allowed only for synthetic demo traffic. Provide an ACM cert and
# an owned DNS hostname before handling genuine customer/support information.
# The default action is intentionally NOT a target group: ECS owns production
# traffic through the dedicated listener rule below.
resource "aws_lb_listener" "http" {
  count             = var.enable_application ? 1 : 0
  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.enable_https ? "redirect" : "fixed-response"
    dynamic "redirect" {
      for_each = local.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    dynamic "fixed_response" {
      for_each = local.enable_https ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "Not found"
        status_code  = "404"
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
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# ECS native blue/green requires the ALB *rule ARN*. Both target groups must
# be associated with a production rule; initial weights are blue=100, green=0.
# With both groups in this rule, a separate publicly reachable test listener
# is not required. ECS updates the rule's weights on deployment.
resource "aws_lb_listener_rule" "production" {
  count        = var.enable_application ? 1 : 0
  listener_arn = local.enable_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue[0].arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.green[0].arn
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  lifecycle {
    # IMPORTANT: ECS owns this action once blue/green starts; Terraform must
    # not reset its weights to blue after a successful green deployment.
    ignore_changes = [action]
  }
}
