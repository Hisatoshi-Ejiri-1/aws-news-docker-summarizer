# Terraform 本体と AWS プロバイダのバージョンを固定する
# （アプリの requirements.txt と同じ考え方で、誰がいつ実行しても同じ結果にするため）
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # このプロジェクトで作るすべてのリソースに自動でタグを付ける
  # → 請求画面で「このシステムにいくらかかったか」を絞り込める
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
