# 環境によって変わる値はすべてここに集める（コード本体には直接書かない）

variable "region" {
  description = "リソースを作るリージョン"
  type        = string
  default     = "ap-northeast-1" # 東京
}

variable "project_name" {
  description = "リソース名の先頭に付ける名前"
  type        = string
  default     = "aws-news-summarizer"
}

variable "schedule_expression" {
  description = "実行タイミング（EventBridge Scheduler の cron 式）"
  type        = string
  default     = "cron(0 8 * * ? *)" # 毎日 8:00
}

variable "schedule_timezone" {
  description = "上の cron 式をどのタイムゾーンで解釈するか"
  type        = string
  default     = "Asia/Tokyo"
}

variable "bedrock_model_id" {
  description = "要約に使う Bedrock のモデル（日本国内の推論プロファイル）"
  type        = string
  default     = "jp.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "image_tag" {
  description = "Lambda にデプロイするコンテナイメージのタグ"
  type        = string
  default     = "latest"
}

variable "alert_email" {
  description = "失敗時の通知を受け取るメールアドレス"
  type        = string
  # 個人情報なので default は置かず、terraform.tfvars で渡す
}
