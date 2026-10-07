# ============================================================
# 本体：コンテナイメージの置き場所（ECR）と Lambda
# ============================================================

resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # terraform destroy でイメージごと消せるようにする

  image_scanning_configuration {
    scan_on_push = true # push のたびに既知の脆弱性をスキャンする（無料）
  }
}

# 古いイメージを自動で消す（ECR は保存容量で課金されるため）
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新5件だけ残す"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# push 済みイメージの「ダイジェスト」（中身から計算される一意なID）を取得する。
# タグ（latest）で指定すると、新しいイメージを push しても Terraform が変更に気づかない。
# ダイジェストで指定すれば、中身が変わったときだけ Lambda が更新される。
data "aws_ecr_image" "app" {
  repository_name = aws_ecr_repository.app.name
  image_tag       = var.image_tag
}

# ログの保存期間を決めるため、ロググループも Terraform で作る
# （Lambda に自動で作らせると、ログが無期限に残り続ける）
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "app" {
  function_name = var.project_name
  role          = aws_iam_role.lambda.arn

  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app.repository_url}@${data.aws_ecr_image.app.image_digest}"
  architectures = ["x86_64"] # docker build の --platform linux/amd64 と合わせる

  # RSS取得 + 最大10件の要約 + Slack送信。外部通信はそれぞれ10秒で打ち切るので、2分あれば十分
  timeout     = 120
  memory_size = 256

  environment {
    variables = {
      TABLE_NAME          = aws_dynamodb_table.sent_articles.name
      SLACK_WEBHOOK_PARAM = aws_ssm_parameter.slack_webhook_url.name
      MODEL_ID            = var.bedrock_model_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}
