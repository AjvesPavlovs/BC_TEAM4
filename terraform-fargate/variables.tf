variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_account_id" {
  type = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Set the 12-digit AWS account ID for this environment."
  }
}

variable "name_prefix" {
  type    = string
  default = "slice-sip-fargate-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name_prefix))
    error_message = "Use 3 to 24 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Approved public subnets, each in a different Availability Zone."
  type        = set(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Specify at least two public subnets for the ALB."
  }
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the demo ALB over HTTP, including the Jenkins egress address."
  type        = list(string)
}

variable "task_execution_role_arn" {
  description = "Existing approved ECS task execution role with CloudWatch Logs access."
  type        = string
}

variable "application_image" {
  description = "Registry image pinned to the digest published by the build."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@sha256:[a-f0-9]{64}$", var.application_image))
    error_message = "Use a registry image reference ending in @sha256:<64 lowercase hex digits>."
  }
}
