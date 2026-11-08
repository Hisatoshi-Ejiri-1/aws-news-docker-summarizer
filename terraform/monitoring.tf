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

# ------------------------------------------------------------
# 「Lambda が起動しなかった」ことを検知するアラーム（v3で追加）
#   上のアラームは「エラーで終わった」ことしか分からない。
#   Scheduler の故障などで Lambda がそもそも呼ばれないと、エラーも出ないので気づけない。
#   そこで「24時間で1回も起動していない」状態そのものを異常として扱う。
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_not_invoked" {
  alarm_name        = "${var.project_name}-not-invoked"
  alarm_description = "AWS News Summarizer の Lambda が24時間起動していません。Scheduler の状態を確認してください。"

  namespace   = "AWS/Lambda"
  metric_name = "Invocations"
  dimensions  = { FunctionName = aws_lambda_function.app.function_name }

  # 5分ごとの実行回数を 288 期間（= 24時間）分見て、
  # すべての期間で 1 未満（= 一度も起動していない）なら ALARM
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 288
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # エラーのアラームとは逆。データがない＝「起動していない」なので異常とみなす
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
