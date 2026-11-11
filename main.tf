# ==============================================================================
# SLICE & IPs CAPSTONE - SSM Only Infrastructure (Ubuntu, eu-west-1)
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

output "public_ip" {
  value       = aws_instance.slice_sip_server.public_ip
  description = "The public IP address of the server."
}