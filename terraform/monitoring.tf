# ============================================================
# 監視：Lambda が失敗したらメールで知らせる
#   コード側で「失敗したら例外を投げる」ようにしたので、ここで初めて失敗を検知できる
# ============================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# 作成後に確認メールが届くので、リンクを押して購読を有効にする必要がある
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name        = "${var.project_name}-errors"
  alarm_description = "AWS News Summarizer の Lambda が失敗しました。CloudWatch Logs を確認してください。"

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = aws_lambda_function.app.function_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # 1日1回しか動かないので、データがない時間帯は「正常」とみなす
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # 復旧したことも知らせる
}
