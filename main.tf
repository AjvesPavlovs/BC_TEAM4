# ==============================================================================
# SLICE & SIP CAPSTONE - SSM Only Infrastructure (Ubuntu, eu-west-1)
# ==============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # Requirement #2: Remote Terraform Backend with State Locking
  backend "s3" {
    bucket         = "slice-sip-terraform-state-devops-t4-0-597765856364-eu-west-1-an"
    key            = "slice-sip/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "your-dynamodb-lock-table"
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_vpc" "default" {
  default = true
}

# Dynamically fetch official Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# Security Group: HTTP/HTTPS open to the public (0.0.0.0/0)
resource "aws_security_group" "slice_sip_sg" {
  name        = "slice-sip-ssm-sg"
  description = "Capstone SG: SSM Managed Instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Public HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Public HTTPS"
    from_port   = 443
    to_port     = 443
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
    Name = "SliceAndSip-SSM-SG"
  }
}

# Look up the pre-existing IAM role
data "aws_iam_role" "ssm_role" {
  name = "Bootcamp-Instance-Profile"
}

# Look up the pre-existing IAM instance profile to bypass user permissions
data "aws_iam_instance_profile" "ssm_profile" {
  name = "Bootcamp-Instance-Profile"
}

# Attach CloudWatch Agent Policy to allow reporting RAM and Disk metrics
resource "aws_iam_role_policy_attachment "cw_agent" {
  role       = data.aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# EC2 Instance configured for SSM access
resource "aws_instance" "slice_sip_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [aws_security_group.slice_sip_sg.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm_profile.name
  user_data              = file("user_data.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "SliceAndSip-Production"
  }
}

# ==============================================================================
# MONITORING & DISCORD NOTIFICATIONS (Requirement #6)
# ==============================================================================

# SNS Topic for Monitoring Alerts
resource "aws_sns_topic" "discord_alerts" {
  name = "discord-monitoring-alerts"
}

# Automatically package index.py into a Lambda zip artifact
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.py"
  output_path = "${path.module}/lambda_payload.zip"
}

# IAM Role for Lambda Translator
resource "aws_iam_role" "lambda_sns_to_discord" {
  name = "lambda_sns_to_discord_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment "lambda_logs" {
  role       = aws_iam_role.lambda_sns_to_discord.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda Function to format and push alerts to Discord Webhook
resource "aws_lambda_function" "discord_notifier" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "sns-to-discord-notifier"
  role             = aws_iam_role.lambda_sns_to_discord.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN" # Replace with your Discord Webhook URL
    }
  }
}

# Subscribe Lambda to the SNS Topic
resource "aws_sns_topic_subscription "lambda_sub" {
  topic_arn = aws_sns_topic.discord_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord_notifier.arn
}

resource "aws_lambda_permission "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.discord_alerts.arn
}

# CloudWatch Alarm: High CPU Utilization (>80%)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "ec2-high-cpu-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Triggered when EC2 CPU exceeds 80%"

  dimensions = {
    InstanceId = aws_instance.slice_sip_server.id
  }

  alarm_actions = [aws_sns_topic.discord_alerts.arn]
}

# CloudWatch Alarm: High Memory Utilization (>85%)
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "ec2-high-memory-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Triggered when EC2 memory usage exceeds 85%"

  dimensions = {
    InstanceId = aws_instance.slice_sip_server.id
  }

  alarm_actions = [aws_sns_topic.discord_alerts.arn]
}

# CloudWatch Alarm: High Disk Utilization (>90%)
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "ec2-high-disk-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "Triggered when root disk usage exceeds 90%"

  dimensions = {
    InstanceId    = aws_instance.slice_sip_server.id
    image_id      = data.aws_ami.ubuntu.id
    instance_type = "t3.medium"
    device        = "xvda1"
    fstype        = "ext4"
    path          = "/"
  }

  alarm_actions = [aws_sns_topic.discord_alerts.arn]
}

output "public_ip" {
  value       = aws_instance.slice_sip_server.public_ip
  description = "The public IP address of the server."
}