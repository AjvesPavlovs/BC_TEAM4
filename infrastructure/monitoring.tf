# Alarms publish State Change events to EventBridge automatically. The rule in
# queues.tf forwards them to the same SQS queue the Discord worker consumes.
resource "aws_cloudwatch_metric_alarm" "ci_cpu" {
  alarm_name          = "${var.project_name}-ci-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Woodpecker CI EC2 CPU over 80%"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = data.aws_instance.ci.id }
}

resource "aws_cloudwatch_metric_alarm" "discord_dlq_has_messages" {
  alarm_name          = "${var.project_name}-discord-dlq-nonempty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Discord messages exhausted retries and reached the DLQ"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.discord_dlq.name }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  count               = var.enable_application ? 1 : 0
  alarm_name          = "${var.project_name}-app-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app[0].name
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = var.enable_database ? 1 : 0
  alarm_name          = "${var.project_name}-db-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.postgres[0].identifier }
}
