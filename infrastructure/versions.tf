terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }

  # No backend is configured yet. Start with local state ONLY in the separate,
  # new infrastructure/ root. Establish an encrypted remote S3 backend and
  # migrate this state before the live presentation (separate bootstrap step).
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SliceAndSip"
      Environment = "bootcamp"
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# An AMI lookup is not necessary here: we reuse the existing CI host.
# Confirm its actual OS before writing the Ansible installation playbook.

locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  enable_https       = trimspace(var.app_certificate_arn) != ""
  discord_channels   = toset(["orders", "invoices", "support", "monitoring"])
}
