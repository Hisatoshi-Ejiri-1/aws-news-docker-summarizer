"""AWS News Summarizer

AWSの新着情報（What's New）を1日1回取得し、
まだ送っていない記事だけを Bedrock で日本語要約して、Slack に1通にまとめて送る。

処理の流れ:
    1. RSSを取得する
    2. DynamoDB と照合して、未送信の記事だけに絞る
    3. Bedrock で1記事ずつ日本語要約する
    4. Slack に1通にまとめて送信する
    5. 送信に成功した記事だけを DynamoDB に「送信済み」として記録する

失敗したときは例外をそのまま投げる。
→ Lambda が「エラー」として記録され、CloudWatch アラームで気づける。
→ 送信済みの記録は5の時点で初めて書くので、失敗した記事は次回もう一度送られる。
"""

import html
import json
import logging
import os
import re
import time

import boto3
import feedparser
import requests

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---- 設定（すべて環境変数で外から渡す）----
FEED_URL = os.environ.get(
    "FEED_URL", "https://aws.amazon.com/about-aws/whats-new/recent/feed/"
)
TABLE_NAME = os.environ["TABLE_NAME"]  # 送信済み記事を記録する DynamoDB テーブル
SLACK_WEBHOOK_PARAM = os.environ["SLACK_WEBHOOK_PARAM"]  # Webhook URL を入れた SSM パラメータ名
MODEL_ID = os.environ.get("MODEL_ID", "jp.anthropic.claude-haiku-4-5-20251001-v1:0")
MAX_ITEMS = int(os.environ.get("MAX_ITEMS", "10"))  # 1回に要約・送信する最大件数
TTL_DAYS = 90  # 送信済み記録を自動で消すまでの日数

HTTP_TIMEOUT = 10  # 秒。外部への通信が固まって Lambda が止まり続けるのを防ぐ

# クライアントはハンドラの外で作る（Lambda が再利用されたとき作り直さずに済む）
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
ssm = boto3.client("ssm")
bedrock = boto3.client("bedrock-runtime")

_webhook_url_cache = None


def get_webhook_url():
    """Slack の Webhook URL を SSM Parameter Store（SecureString）から取得する。"""
    global _webhook_url_cache
    if _webhook_url_cache is None:
        res = ssm.get_parameter(Name=SLACK_WEBHOOK_PARAM, WithDecryption=True)
        _webhook_url_cache = res["Parameter"]["Value"]
    return _webhook_url_cache


def fetch_entries():
    """RSSを取得して記事のリストを返す。

    feedparser.parse(URL) だとタイムアウトを指定できないので、
    取得は requests で行い、解析だけを feedparser に任せる。
    """
    res = requests.get(FEED_URL, timeout=HTTP_TIMEOUT)
    res.raise_for_status()
    feed = feedparser.parse(res.content)
    if feed.bozo and not feed.entries:
        raise RuntimeError(f"RSSの解析に失敗しました: {feed.bozo_exception}")
    return feed.entries


def entry_id(entry):
    """記事を一意に識別するキー。guid があればそれを、なければURLを使う。"""
    return entry.get("id") or entry.get("link")


def filter_unsent(entries):
    """DynamoDB に記録がない（＝まだ送っていない）記事だけを返す。"""
    unsent = []
    for entry in entries:
        res = table.get_item(Key={"article_id": entry_id(entry)})
        if "Item" not in res:
            unsent.append(entry)
    return unsent


def clean_text(raw):
    """RSSの本文に含まれるHTMLタグを取り除く。"""
    text = re.sub(r"<[^>]+>", " ", raw or "")
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def summarize(entry):
    """Bedrock（Converse API）で記事を日本語で2文以内に要約する。"""
    prompt = (
        "次のAWSの新着情報を、日本語で2文以内に要約してください。"
        "何が新しくなり、誰にとって何がうれしいのかが分かるように書いてください。"
        "要約の文章だけを出力してください。\n\n"
        f"タイトル: {entry.get('title', '')}\n"
        f"本文: {clean_text(entry.get('summary', ''))[:3000]}"
    )
    res = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 300, "temperature": 0.2},
    )
    return res["output"]["message"]["content"][0]["text"].strip()


def build_message(items, skipped_count):
    """Slack に送る1通分のメッセージを組み立てる。"""
    lines = [f"*AWS新着情報（{len(items)}件）*"]
    for entry, summary in items:
        lines.append(f"\n• <{entry.get('link')}|{entry.get('title')}>\n{summary}")
    if skipped_count:
        lines.append(f"\n※ ほかに {skipped_count} 件の新着がありました（要約は省略）")
    return "\n".join(lines)


def send_slack(message):
    """Slack に送信する。失敗したら例外を投げる。"""
    res = requests.post(
        get_webhook_url(), json={"text": message}, timeout=HTTP_TIMEOUT
    )
    res.raise_for_status()


def mark_sent(entries):
    """記事を送信済みとして記録する。TTL により一定期間後に自動で消える。"""
    expires_at = int(time.time()) + TTL_DAYS * 24 * 60 * 60
    with table.batch_writer() as batch:
        for entry in entries:
            batch.put_item(Item={"article_id": entry_id(entry), "expires_at": expires_at})


def lambda_handler(event, context):
    entries = fetch_entries()
    unsent = filter_unsent(entries)
    logger.info("取得 %d 件 / 未送信 %d 件", len(entries), len(unsent))

    if not unsent:
        return {"sent": 0}

    targets = unsent[:MAX_ITEMS]
    items = [(entry, summarize(entry)) for entry in targets]
    send_slack(build_message(items, skipped_count=len(unsent) - len(targets)))

    # 要約を省略した分も「送信済み」にする（件数としては通知済みのため）
    mark_sent(unsent)
    logger.info("%d 件を送信しました", len(targets))
    return {"sent": len(targets), "skipped": len(unsent) - len(targets)}
