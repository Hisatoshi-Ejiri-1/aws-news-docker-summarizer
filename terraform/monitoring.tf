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

  # OK の通知は送らない（v3で変更）
  #   1日1回しか動かないので、失敗しても5分後にはデータがなくなり、自動で OK に戻ってしまう。
  #   壊れたままなのに OK のメールが届き、正常だと誤解する原因になった（2026年10月の障害）。
  #   本当に復旧したかどうかは、下の「26時間成功なし」のアラームで判断する。
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------
# 「26時間以上、一度も成功していない」ことを検知するアラーム（v3で追加）
#   上のエラーのアラームは、失敗した直後しか ALARM にならず、5分で OK に戻る。
#   そこで「失敗」ではなく「成功が来ないこと」そのものを異常として扱う。
#     成功回数 = 起動回数 - エラー回数
#   これなら、次のどちらの場合も検知できる。
#     - 起動はするが失敗し続ける（2026年10月の障害はこれ）
#     - Scheduler の故障などで、そもそも起動しない
#   1日1回の実行なので、時刻のずれや自動再実行を考えて、26時間で判定する。
#   成功するまで ALARM のままなので、こちらの OK は「本当に復旧した」という意味になる。
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "no_success" {
  alarm_name        = "${var.project_name}-no-success"
  alarm_description = "AWS News Summarizer が26時間以上一度も成功していません。CloudWatch Logs を確認してください。"

  # 1時間ごとの成功回数を26期間（= 26時間）分見て、すべて 1 未満なら ALARM
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 26

  # データがない ＝ 起動していない ＝ 成功していない、なので異常とみなす
  treat_missing_data = "breaching"

  metric_query {
    id = "invocations"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      dimensions  = { FunctionName = aws_lambda_function.app.function_name }
      period      = 3600
      stat        = "Sum"
    }
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.app.function_name }
      period      = 3600
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "successes"
    expression  = "invocations - FILL(errors, 0)"
    label       = "成功回数"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
