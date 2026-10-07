# apply のあとに表示される値（次の作業で使う）

output "ecr_repository_url" {
  description = "docker push 先"
  value       = aws_ecr_repository.app.repository_url
}

output "lambda_function_name" {
  description = "手動テストで使う関数名"
  value       = aws_lambda_function.app.function_name
}

output "slack_webhook_parameter_name" {
  description = "Webhook URL を入れる SSM パラメータ名"
  value       = aws_ssm_parameter.slack_webhook_url.name
}
