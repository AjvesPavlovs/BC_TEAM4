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

