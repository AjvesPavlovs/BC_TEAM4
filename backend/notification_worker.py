"""Deliver SQS notification events to the four Discord channels."""
from __future__ import annotations

import json
import os
import time
import urllib.request
from typing import Any

import boto3

CHANNEL_ENV = {
    "orders": "DISCORD_ORDERS_SECRET_ID",
    "invoices": "DISCORD_INVOICES_SECRET_ID",
    "support": "DISCORD_SUPPORT_SECRET_ID",
    "monitoring": "DISCORD_MONITORING_SECRET_ID",
}


class SecretStore:
    """Fetch Discord webhook URLs from Secrets Manager without logging them."""

    def __init__(self, client: Any):
        self.client = client
        self.cache: dict[str, str] = {}

    def webhook_for(self, channel: str) -> str:
        env_name = CHANNEL_ENV.get(channel)
        secret_id = os.environ.get(env_name or "")
        if not env_name or not secret_id:
            raise RuntimeError(f"No Secrets Manager secret configured for channel {channel}")
        if secret_id not in self.cache:
            response = self.client.get_secret_value(SecretId=secret_id)
            secret_string = response.get("SecretString")
            if not secret_string:
                raise RuntimeError(f"Secret {secret_id} has no SecretString")
            try:
                parsed = json.loads(secret_string)
                url = parsed.get("url") if isinstance(parsed, dict) else secret_string
            except json.JSONDecodeError:
                url = secret_string
            if not isinstance(url, str) or not url.startswith("https://discord.com/api/webhooks/"):
                raise RuntimeError(f"Secret {secret_id} is not a valid Discord webhook URL")
            self.cache[secret_id] = url
        return self.cache[secret_id]


def discord_message(event: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Return (channel, Discord JSON payload) for app or CloudWatch events."""
    if event.get("source") == "aws.cloudwatch" or event.get("detail-type") == "CloudWatch Alarm State Change":
        detail = event.get("detail") or {}
        alarm_name = detail.get("alarmName", "Unknown CloudWatch alarm")
        state = (detail.get("state") or {}).get("value", "UNKNOWN").upper()
        reason = (detail.get("state") or {}).get("reason", "No reason provided")
        color = 15158332 if state == "ALARM" else 3066993
        return "monitoring", {
            "embeds": [{
                "title": f"CloudWatch alert: {alarm_name}",
                "description": f"**Status:** {state}\n**Reason:** {reason[:1500]}",
                "color": color,
            }],
            "allowed_mentions": {"parse": []},
        }

    channel = event.get("channel")
    if channel not in CHANNEL_ENV:
        raise ValueError("Notification event has an unsupported channel")
    title = str(event.get("title", "Slice & Sip notification"))[:250]
    description = str(event.get("description", "New event received."))[:3500]
    colors = {
        "orders": 5763719,
        "invoices": 3447003,
        "support": 10181046,
        "monitoring": 15105570,
    }
    return channel, {
        "embeds": [{"title": title, "description": description, "color": colors[channel]}],
        "allowed_mentions": {"parse": []},
    }


def send_discord(webhook_url: str, payload: dict[str, Any]) -> None:
    request = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "SliceAndSip-Notifications/1.0"},
        method="POST",
    )
    # Discord normally returns HTTP 204 for a successful webhook execution.
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status not in (200, 204):
            raise RuntimeError(f"Discord returned HTTP {response.status}")


def process_message(sqs: Any, message: dict[str, Any], secrets: SecretStore) -> None:
    receipt = message["ReceiptHandle"]
    event = json.loads(message["Body"])
    channel, payload = discord_message(event)
    webhook_url = secrets.webhook_for(channel)
    send_discord(webhook_url, payload)
    sqs.delete_message(QueueUrl=os.environ["SQS_QUEUE_URL"], ReceiptHandle=receipt)


def main() -> None:
    queue_url = os.environ.get("SQS_QUEUE_URL")
    region = os.environ.get("AWS_REGION", "eu-west-1")
    if not queue_url:
        raise RuntimeError("SQS_QUEUE_URL is required")

    session = boto3.session.Session(region_name=region)
    sqs = session.client("sqs")
    secrets_manager = session.client("secretsmanager")
    secrets = SecretStore(secrets_manager)
    print("Discord notification worker started")

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,
                VisibilityTimeout=60,
                AttributeNames=["ApproximateReceiveCount"],
            )
            for message in response.get("Messages", []):
                try:
                    process_message(sqs, message, secrets)
                    print("Discord notification delivered")
                except Exception as exc:
                    # Do not delete a failed message. SQS visibility timeout and
                    # the queue redrive policy handle retry and eventual DLQ.
                    print(f"Notification delivery failed ({type(exc).__name__}); SQS will retry")
        except Exception as exc:
            print(f"SQS receive failed ({type(exc).__name__}); retrying")
            time.sleep(5)


if __name__ == "__main__":
    main()
