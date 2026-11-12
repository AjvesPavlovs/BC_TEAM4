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

# Woodpecker's HTTPS proxy is public. Administration uses SSM over outbound HTTPS.
resource "aws_security_group" "slice_sip_sg" {
  name        = "slice-sip-ssm-sg"
  description = "Capstone SG: SSM Managed Instance"
  vpc_id      = data.aws_vpc.default.id

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

# Look up the instructor-approved SSM instance profile.
data "aws_iam_instance_profile" "ssm_profile" {
  name = "Bootcamp-Instance-Profile"
}

# EC2 Instance configured for SSM access
resource "aws_instance" "slice_sip_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [aws_security_group.slice_sip_sg.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm_profile.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "SliceAndSip-Woodpecker"
  }
}

output "public_ip" {
  value       = aws_instance.slice_sip_server.public_ip
  description = "The public IP address of the server."
}
