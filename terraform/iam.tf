# ============================================================
# 権限（IAM）
#   方針：最小権限。「どの操作を」「どのリソースに対して」を必ず両方絞る。
#   Resource = "*" は使わない（KMS の1か所だけ、条件付きで例外）。
# ============================================================

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # 推論プロファイルID（jp.anthropic...）から、元のモデルID（anthropic...）を取り出す
  foundation_model_id = replace(var.bedrock_model_id, "/^[a-z]+\\./", "")
}

# ---- Lambda が使うロール ----
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda"

  # 信頼ポリシー：「このロールを引き受けられるのは Lambda サービスだけ」
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteOwnLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        # 自分のロググループにだけ書ける
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid    = "ReadWriteSentArticles"
        Effect = "Allow"
        # 読む・書くだけ。テーブルの削除や全件スキャンはできない
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:BatchWriteItem"]
        Resource = aws_dynamodb_table.sent_articles.arn
      },
      {
        Sid      = "ReadSlackWebhook"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.slack_webhook_url.arn
      },
      {
        Sid      = "DecryptViaSsmOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        # 復号は「SSM 経由の呼び出し」に限る。KMS を直接呼んで他のデータを復号することはできない
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
      {
        Sid      = "InvokeJapanInferenceProfile"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${var.bedrock_model_id}"
      },
      {
        Sid    = "InvokeModelOnlyThroughProfile"
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        # 推論プロファイルが東京か大阪のモデルに振り分ける。その振り分け先だけを許可し、
        # しかも「日本の推論プロファイル経由の呼び出し」に限定する（国外リージョンでは動かない）
        Resource = [
          "arn:aws:bedrock:ap-northeast-1::foundation-model/${local.foundation_model_id}",
          "arn:aws:bedrock:ap-northeast-3::foundation-model/${local.foundation_model_id}",
        ]
        Condition = {
          StringLike = {
            "bedrock:InferenceProfileArn" = "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${var.bedrock_model_id}"
          }
        }
      },
    ]
  })
}

# ---- EventBridge Scheduler が使うロール ----
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # 自分のアカウントのスケジュールからの引き受けに限る（他アカウントからの悪用防止）
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-scheduler"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.app.arn # この Lambda を起動することしかできない
    }]
  })
}
