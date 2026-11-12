"""Publish committed PostgreSQL outbox events to SQS (at-least-once)."""
from __future__ import annotations

import json
import os
import time
from typing import Any

import boto3

from database import get_connection


BATCH_SIZE = 10
POLL_SECONDS = 5


def publish_batch(sqs: Any, queue_url: str) -> int:
    published = 0
    with get_connection() as connection:
        with connection.transaction():
            with connection.cursor() as cursor:
                cursor.execute(
                    """SELECT id, payload
                       FROM notification_outbox
                       WHERE published_at IS NULL
                       ORDER BY id
                       LIMIT %s
                       FOR UPDATE SKIP LOCKED""",
                    (BATCH_SIZE,),
                )
                rows = cursor.fetchall()
                for row_id, payload in rows:
                    body = payload if isinstance(payload, str) else json.dumps(payload)
                    try:
                        sqs.send_message(QueueUrl=queue_url, MessageBody=body)
                    except Exception as exc:
                        cursor.execute(
                            """UPDATE notification_outbox
                               SET publish_attempts = publish_attempts + 1,
                                   last_error = %s
                               WHERE id = %s""",
                            (type(exc).__name__, row_id),
                        )
                        # Keep this and later records pending; next poll retries.
                        break
                    cursor.execute(
                        """UPDATE notification_outbox
                           SET published_at = NOW(),
                               publish_attempts = publish_attempts + 1,
                               last_error = NULL
                           WHERE id = %s""",
                        (row_id,),
                    )
                    published += 1
    return published


def main() -> None:
    queue_url = os.environ.get("SQS_QUEUE_URL")
    region = os.environ.get("AWS_REGION", "eu-west-1")
    if not queue_url:
        raise RuntimeError("SQS_QUEUE_URL is required")
    sqs = boto3.client("sqs", region_name=region)
    print("Outbox publisher started")
    while True:
        try:
            count = publish_batch(sqs, queue_url)
            if count:
                print(f"Published {count} notification event(s) to SQS")
        except Exception as exc:
            print(f"Outbox poll failed ({type(exc).__name__}); retrying")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
