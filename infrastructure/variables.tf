variable "aws_region" {
  type        = string
  description = "AWS region; all resources are placed here."
  default     = "eu-west-1"
}

variable "project_name" {
  type        = string
  description = "Short lowercase resource prefix; keep stable after the first apply."
  default     = "slice-sip"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Use 3-21 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "existing_ci_instance_id" {
  type        = string
  description = "Existing instructor-provided EC2 for Woodpecker and Ansible (read-only lookup)."
  validation {
    condition     = can(regex("^i-[0-9a-f]{8,17}$", var.existing_ci_instance_id))
    error_message = "Use an EC2 instance ID like i-0123456789abcdef0."
  }
}

variable "enable_database" {
  type        = bool
  description = "Create chargeable RDS PostgreSQL instance and subnet group."
  default     = false
}

variable "enable_application" {
  type        = bool
  description = "Create chargeable ALB and Fargate services; turn on only AFTER images are pushed to ECR and database is enabled."
  default     = false
}

variable "frontend_image_tag" {
  type        = string
  description = "Pre-pushed immutable frontend ECR image tag for INITIAL service creation."
  default     = ""
}

variable "backend_image_tag" {
  type        = string
  description = "Pre-pushed immutable backend ECR image tag for INITIAL service creation."
  default     = ""
}

variable "app_certificate_arn" {
  type        = string
  description = "Optional issued ACM certificate ARN. If omitted, the DEMO ALB only serves HTTP (no real customer data)."
  default     = ""
}


variable "blue_green_bake_minutes" {
  type        = number
  description = "Time both Fargate revisions remain running after traffic shifts; brief demo rollback window."
  default     = 5
  validation {
    condition     = var.blue_green_bake_minutes >= 1 && var.blue_green_bake_minutes <= 60 && floor(var.blue_green_bake_minutes) == var.blue_green_bake_minutes
    error_message = "Use a whole-number bake time between 1 and 60 minutes for the bootcamp demo."
  }
}

# Shared bootcamp VPC inputs. Supply actual approved IDs via local terraform.tfvars
# (ignored by Git); never create or modify the bootcamp network here.
variable "existing_vpc_id" {
  type        = string
  description = "Instructor-approved existing bootcamp VPC ID (eu-west-1)."
  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.existing_vpc_id))
    error_message = "Specify a valid existing VPC ID."
  }
}

variable "alb_public_subnet_ids" {
  type        = list(string)
  description = "Two approved IGW-routed public subnet IDs in distinct AZs for the ALB."
  validation {
    condition     = length(var.alb_public_subnet_ids) == 2 && length(distinct(var.alb_public_subnet_ids)) == 2
    error_message = "Supply two distinct public subnet IDs."
  }
}

variable "ecs_private_subnet_ids" {
  type        = list(string)
  description = "Two approved NAT-routed private subnet IDs in distinct AZs for Fargate."
  validation {
    condition     = length(var.ecs_private_subnet_ids) == 2 && length(distinct(var.ecs_private_subnet_ids)) == 2
    error_message = "Supply two distinct NAT-routed private subnet IDs."
  }
}

variable "rds_isolated_subnet_ids" {
  type        = list(string)
  description = "Two approved isolated subnet IDs in distinct AZs for RDS."
  validation {
    condition     = length(var.rds_isolated_subnet_ids) == 2 && length(distinct(var.rds_isolated_subnet_ids)) == 2
    error_message = "Supply two distinct isolated subnet IDs."
  }
}

# Phase 6K: execution role is pre-existing and read-only.
variable "existing_ecs_execution_role_name" {
  type        = string
  description = "Approved existing ECS execution role, usually ecsTaskExecutionRole."
  default     = "ecsTaskExecutionRole"
}

# Keep these empty until the instructor provides the actual ARN. A preview with
# enable_application=false still works; enabling it fails closed until set.
variable "app_task_role_arn" {
  type        = string
  description = "Instructor-managed task role for the app's RDS secret reads."
  default     = ""
  validation {
    condition     = var.app_task_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.app_task_role_arn))
    error_message = "Use an IAM role ARN or leave blank while awaiting instructor approval."
  }
}

variable "notifications_task_role_arn" {
  type        = string
  description = "Instructor-managed task role for SQS and notification secrets."
  default     = ""
  validation {
    condition     = var.notifications_task_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.notifications_task_role_arn))
    error_message = "Use an IAM role ARN or leave blank while awaiting instructor approval."
  }
}

variable "ecs_infrastructure_role_arn" {
  type        = string
  description = "Instructor-managed ECS infrastructure role for blue/green ALB traffic changes."
  default     = ""
  validation {
    condition     = var.ecs_infrastructure_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.ecs_infrastructure_role_arn))
    error_message = "Use an IAM role ARN or leave blank while awaiting instructor approval."
  }
}
