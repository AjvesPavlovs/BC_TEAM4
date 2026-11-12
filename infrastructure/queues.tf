resource "aws_sqs_queue" "discord_dlq" {
  name                      = "${var.project_name}-discord-dlq"
  message_retention_seconds = 1209600 # 14 days for manual diagnosis
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "discord" {
  name                       = "${var.project_name}-discord-events"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.discord_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "discord_dlq" {
  queue_url = aws_sqs_queue.discord_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.discord.arn]
  })
}

resource "aws_cloudwatch_event_rule" "alarm_changes" {
  name        = "${var.project_name}-alarm-changes"
  description = "Forward CloudWatch alarm state changes to the Discord worker via SQS"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
  })
}

resource "aws_cloudwatch_event_target" "alarm_to_sqs" {
  depends_on = [aws_sqs_queue_policy.discord_eventbridge]
  rule = aws_cloudwatch_event_rule.alarm_changes.name
  arn  = aws_sqs_queue.discord.arn
}

resource "aws_sqs_queue_policy" "discord_eventbridge" {
  queue_url = aws_sqs_queue.discord.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeAlarms"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.discord.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.alarm_changes.arn } }
    }]
  })
}
