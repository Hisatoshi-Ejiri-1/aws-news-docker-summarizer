# ============================================================
# 起動の仕組み：EventBridge Scheduler
#   従来の EventBridge ルールの cron は UTC 固定。
#   Scheduler はタイムゾーンを指定できるので「毎朝8時(JST)」をそのまま書ける。
# ============================================================

resource "aws_scheduler_schedule" "daily" {
  name = "${var.project_name}-daily"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF" # 指定時刻ちょうどに起動する
  }

  target {
    arn      = aws_lambda_function.app.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
