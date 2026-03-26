import feedparser
import requests  
import json
import os

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL")
def send_slack(message):
    payload = {"text": message}
    requests.post(SLACK_WEBHOOK_URL, data=json.dumps(payload))

def get_aws_news():
    print("--- ニュースを取得してSlackに送信します ---")
    url = "https://aws.amazon.com/about-aws/whats-new/recent/feed/"
    feed = feedparser.parse(url)
    
    for entry in feed.entries[:3]:
        msg = f"【AWS新着】\nタイトル: {entry.title}\nURL: {entry.link}"
        print(f"送信中: {entry.title}")
        send_slack(msg)

def lambda_handler(event, context):  
    get_aws_news()
    return {
        'statusCode': 200,
        'body': 'Success'
    }