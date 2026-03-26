🛰️ AWS News Summarizer (Docker on Lambda)  
📌 概要
AWSの最新ニュースフィードを取得し、要約してSlackに通知するサーバーレスシステムです。
従来のZipデプロイではなく、Dockerコンテナを利用したデプロイを採用することで、開発環境と本番環境の完全な一致と、ライブラリ依存関係の容易な管理を実現しました。

🛠️ 技術スタック
Language: Python 3.12

Infrastructure: AWS (Lambda, ECR, EventBridge, IAM)

Container: Docker

Library: feedparser, requests

💡 こだわったポイント・解決した課題
・ コンテナ化による再現性の向上

以前のZipデプロイではライブラリのパス問題が発生していましたが、Dockerfileによるイメージ化を行うことで、ローカル環境（Docker Desktop）でのテスト結果をそのまま本番環境に反映させることが可能になりました。

・ マルチプラットフォームビルドの対応

ローカル環境とAWS LambdaのCPUアーキテクチャの差異によりデプロイエラーが発生しましたが、--platform linux/amd64 を指定したビルドを行うことで解決しました。

・ セキュリティの考慮

Secret Scanning によるリスクを回避するため、Webhook URL等の機密情報はコードにハードコードせず、AWS Lambdaの環境変数から取得する実装（os.environ）としています。
