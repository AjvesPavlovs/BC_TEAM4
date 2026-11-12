output "aws_region" {
  value = var.aws_region
}
output "ci_instance_id" {
  value = data.aws_instance.ci.id
}
output "ci_public_ip" {
  description = "Reported existing EC2 public IP (may be empty while stopped). Terraform does not allocate one."
  value       = data.aws_instance.ci.public_ip
}
output "ci_instance_profile" {
  description = "Existing instructor-managed instance profile."
  value       = data.aws_instance.ci.iam_instance_profile
}
output "frontend_ecr_url" {
  value = aws_ecr_repository.frontend.repository_url
}
output "backend_ecr_url" {
  value = aws_ecr_repository.backend.repository_url
}
output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}
output "discord_queue_url" {
  value = aws_sqs_queue.discord.id
}
output "discord_dlq_url" {
  value = aws_sqs_queue.discord_dlq.id
}
output "discord_secret_names" {
  value = { for channel, secret in aws_secretsmanager_secret.discord : channel => secret.name }
}
output "rds_endpoint" {
  value = var.enable_database ? aws_db_instance.postgres[0].endpoint : "Database not enabled"
}
output "app_url" {
  value = var.enable_application ? (local.enable_https ? "https://<your-app-domain>" : "http://${aws_lb.app[0].dns_name}") : "Application not enabled"
}
output "codedeploy_app_name" {
  value = var.enable_application ? aws_codedeploy_app.app[0].name : "Application not enabled"
}
output "codedeploy_group_name" {
  value = var.enable_application ? aws_codedeploy_deployment_group.app[0].deployment_group_name : "Application not enabled"
}
