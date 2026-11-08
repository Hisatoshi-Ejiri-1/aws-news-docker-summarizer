# Terraform 本体と AWS プロバイダのバージョンを固定する
# （アプリの requirements.txt と同じ考え方で、誰がいつ実行しても同じ結果にするため）
terraform {
  required_version = ">= 1.10"

  # tfstate（Terraform が作ったものの記録）を S3 に置く（v3で追加）
  #   - PC が壊れても記録が失われない（バケットのバージョニングで過去の状態にも戻せる）
  #   - use_lockfile：S3 上にロックファイルを置き、同時に2人が apply して記録が壊れるのを防ぐ
  #     （Terraform 1.10 から、DynamoDB を使わずに S3 だけでロックできる）
  # バケット自体は Terraform の外で作る（記録の置き場所を、記録で管理することはできないため）
  backend "s3" {
    bucket       = "tfstate-767397749706-aws-news-summarizer"
    key          = "aws-news-summarizer/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }

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
