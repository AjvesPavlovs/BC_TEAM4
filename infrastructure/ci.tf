# Reuse the instructor-provided bootcamp EC2 instance for Woodpecker + Ansible.
# DATA SOURCE ONLY: Terraform reads this existing host, but does not own, start,
# stop, modify, replace, or destroy it. The application is hosted on ECS Fargate.
data "aws_instance" "ci" {
  instance_id = var.existing_ci_instance_id
}
