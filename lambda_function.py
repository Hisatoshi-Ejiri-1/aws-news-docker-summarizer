"""AWS News Summarizer

AWSの新着情報（What's New）を1日1回取得し、
まだ送っていない記事だけを Bedrock で日本語要約して、Slack に1通にまとめて送る。

処理の流れ:
    1. RSSを取得する
    2. DynamoDB と照合して、未送信の記事だけに絞る
    3. Bedrock で1記事ずつ日本語要約する
    4. Slack に1通にまとめて送信する
    5. 送信に成功した記事だけを DynamoDB に「送信済み」として記録する

縮退運転（v3で追加）:
    要約（Bedrock）に失敗しても、処理全体は止めない。
    要約できなかった記事はタイトルと URL だけを送り、
    Slack のメッセージ先頭に「要約に失敗した」ことを書いて、普段見る場所で気づけるようにする。
    （2026年10月、Bedrock の利用停止で1か月間1件も届かなかった障害への対策）

それ以外の失敗（RSS の取得、Slack への送信など）は例外をそのまま投げる。
→ Lambda が「エラー」として記録され、CloudWatch アラームで気づける。
→ 送信済みの記録は5の時点で初めて書くので、失敗した記事は次回もう一度送られる。
"""

import html
import logging
import os
import re
import time

import boto3
from botocore.config import Config
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
MAX_ITEMS = int(os.environ.get("MAX_ITEMS", "10"))  # 1回に要約する最大件数
MAX_LIST_ITEMS = 50  # 要約しない記事を、タイトルと URL だけで一覧にする最大件数
TTL_DAYS = 90  # 送信済み記録を自動で消すまでの日数

HTTP_TIMEOUT = 10  # 秒。外部への通信が固まって Lambda が止まり続けるのを防ぐ

# クライアントはハンドラの外で作る（Lambda が再利用されたとき作り直さずに済む）
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
ssm = boto3.client("ssm")
# Bedrock が応答しないときに Lambda のタイムアウト（120秒）まで待ち続けないよう、短めに打ち切る
bedrock = boto3.client(
    "bedrock-runtime",
    config=Config(connect_timeout=5, read_timeout=20, retries={"max_attempts": 2}),
)

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


def format_entry(entry, summary=None):
    """記事1件分の行。要約がなければタイトルと URL だけにする。"""
    line = f"• <{entry.get('link')}|{entry.get('title')}>"
    return f"{line}\n{summary}" if summary else line


def build_message(items, others, summary_failed):
    """Slack に送る1通分のメッセージを組み立てる。

    items: 要約を試みた記事（entry, summary）のリスト。要約に失敗した記事は summary が None
    others: 件数の上限を超えたため、要約しなかった記事のリスト
    summary_failed: 要約に失敗したかどうか
    """
    lines = []
    if summary_failed:
        lines.append(
            ":warning: *要約に失敗したため、一部またはすべての記事をタイトルと URL のみで送っています。*"
            "\nCloudWatch Logs を確認してください。\n"
        )
    lines.append(f"*AWS新着情報（{len(items) + len(others)}件）*")
    for entry, summary in items:
        lines.append("\n" + format_entry(entry, summary))

    if others:
        shown = others[:MAX_LIST_ITEMS]
        lines.append(f"\n*ほかの新着（{len(others)}件、要約なし）*")
        lines.extend(format_entry(entry) for entry in shown)
        if len(others) > len(shown):
            lines.append(f"ほか {len(others) - len(shown)} 件")
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


def summarize_all(entries):
    """記事を1件ずつ要約する。失敗しても止めずに、要約なし（None）として扱う。

    1件でも失敗したら、残りの記事は要約を試みない。
    Bedrock 自体が使えない（利用停止、障害など）ときは残りもほぼ確実に失敗するので、
    無駄な呼び出しで時間を使わず、タイトルと URL だけを早く届けるため。
    """
    items = []
    failed = False
    for entry in entries:
        summary = None
        if not failed:
            try:
                summary = summarize(entry)
            except Exception:
                failed = True
                logger.exception("要約に失敗しました。残りの記事はタイトルと URL のみで送ります: %s", entry.get("link"))
        items.append((entry, summary))
    return items, failed


def lambda_handler(event, context):
    entries = fetch_entries()
    unsent = filter_unsent(entries)
    logger.info("取得 %d 件 / 未送信 %d 件", len(entries), len(unsent))

    if not unsent:
        return {"sent": 0}

    targets = unsent[:MAX_ITEMS]
    others = unsent[MAX_ITEMS:]
    items, summary_failed = summarize_all(targets)
    send_slack(build_message(items, others, summary_failed))

    # Slack への送信に成功したので、すべて送信済みとして記録する
    mark_sent(unsent)
    summarized = sum(1 for _, summary in items if summary)
    if summary_failed:
        logger.warning("縮退運転で送信しました（要約 %d 件 / 全 %d 件）", summarized, len(unsent))
    else:
        logger.info("%d 件を送信しました（要約 %d 件）", len(unsent), summarized)
    return {"sent": len(unsent), "summarized": summarized, "degraded": summary_failed}
