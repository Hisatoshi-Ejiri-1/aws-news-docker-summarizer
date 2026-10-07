# ============================================================
# データの置き場所
#   - DynamoDB：送信済みの記事を記録する（二重送信を防ぐ）
#   - SSM Parameter Store：Slack の Webhook URL を暗号化して保管する
# ============================================================

# ---- DynamoDB：送信済み記事の記録 ----
resource "aws_dynamodb_table" "sent_articles" {
  name = "${var.project_name}-sent-articles"

  # オンデマンド課金：使った分だけ払う。
  # 1日1回・数十件の読み書きしかないので、容量を事前に確保する方式より安く、管理も不要。
  billing_mode = "PAY_PER_REQUEST"

  # 記事ID（RSS の guid）をキーにする。「この記事を送ったか？」を1回の検索で判定できる
  hash_key = "article_id"

  attribute {
    name = "article_id"
    type = "S" # 文字列
  }

  # TTL：expires_at に書いた時刻を過ぎた記録を DynamoDB が自動で消す（無料）。
  # RSS に載るのは最近の記事だけなので、古い記録を持ち続ける意味がない。
  # → テーブルが無限に大きくならず、削除用のプログラムも不要。
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# ---- SSM Parameter Store：Slack の Webhook URL ----
resource "aws_ssm_parameter" "slack_webhook_url" {
  name        = "/${var.project_name}/slack-webhook-url"
  description = "Slack Incoming Webhook URL"

  # SecureString：KMS で暗号化して保存される。
  # Lambda の環境変数と違い、コンソールを開いても平文では表示されない。
  type = "SecureString"

  # 本物の URL はここに書かない。
  # Terraform に書いた値は tfstate ファイルに平文で残るため。
  # → Terraform は「入れ物」だけ作り、中身はあとで AWS CLI から入れる（README に手順を書く）
  value = "PLACEHOLDER"

  lifecycle {
    # CLI で入れた本物の値を、次の terraform apply で PLACEHOLDER に戻さないようにする
    ignore_changes = [value]
  }
}
