# Bootcamp-managed networking is REFERENCED, never created or modified here.
# Explicit instructor approval is required before using shared subnets.
# Private ECS tasks egress via the existing NAT gateway; isolated RDS subnets
# have no default route. Terraform only manages Slice & Sip security groups.
data "aws_vpc" "bootcamp" {
  id = var.existing_vpc_id
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "Customer-facing Application Load Balancer"
  vpc_id      = data.aws_vpc.bootcamp.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = local.enable_https ? 1 : 0
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "app" {
  name_prefix = "${var.project_name}-app-"
  description = "Fargate web application: accepts requests only from ALB"
  vpc_id      = data.aws_vpc.bootcamp.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "notifications" {
  name_prefix = "${var.project_name}-notify-"
  description = "Fargate notification workers: outbound only"
  vpc_id      = data.aws_vpc.bootcamp.id
}

resource "aws_vpc_security_group_egress_rule" "notifications_all" {
  security_group_id = aws_security_group.notifications.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "database" {
  name_prefix = "${var.project_name}-db-"
  description = "Private PostgreSQL; only Fargate API and notification publisher"
  vpc_id      = data.aws_vpc.bootcamp.id
}

resource "aws_vpc_security_group_ingress_rule" "app_to_db" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "notifications_to_db" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.notifications.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
