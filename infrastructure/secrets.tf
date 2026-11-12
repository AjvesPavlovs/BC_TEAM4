# Create only secret METADATA. Do not put webhook values in Terraform or state.
# Populate each secret AFTER apply using the AWS Secrets Manager Console.
resource "aws_secretsmanager_secret" "discord" {
  for_each                = local.discord_channels
  name                    = "${var.project_name}/discord/${each.key}"
  description             = "Slice & Sip Discord ${each.key} incoming webhook (populate manually)"
  recovery_window_in_days = 7
}
