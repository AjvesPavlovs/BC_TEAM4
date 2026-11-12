from notification_worker import SecretStore, discord_message


class FakeSecretsManager:
    def __init__(self):
        self.calls = []

    def get_secret_value(self, SecretId):
        self.calls.append(SecretId)
        return {"SecretString": '{"url":"https://discord.com/api/webhooks/123/abc"}'}


def test_order_event_routes_to_orders_channel():
    channel, payload = discord_message({
        "event_type": "order.created",
        "channel": "orders",
        "title": "New order",
        "description": "Order ORD-2026-000001",
    })
    assert channel == "orders"
    assert payload["embeds"][0]["title"] == "New order"
    assert payload["allowed_mentions"] == {"parse": []}


def test_cloudwatch_alarm_routes_to_monitoring():
    channel, payload = discord_message({
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {
            "alarmName": "cpu-high",
            "state": {"value": "ALARM", "reason": "CPU crossed threshold"},
        },
    })
    assert channel == "monitoring"
    assert "cpu-high" in payload["embeds"][0]["title"]
    assert "ALARM" in payload["embeds"][0]["description"]


def test_secret_store_caches_url_and_does_not_log_it(monkeypatch):
    monkeypatch.setenv("DISCORD_ORDERS_SECRET_ID", "slicesip/discord/orders")
    client = FakeSecretsManager()
    store = SecretStore(client)
    first = store.webhook_for("orders")
    second = store.webhook_for("orders")
    assert first == second
    assert client.calls == ["slicesip/discord/orders"]


def test_unknown_event_channel_is_rejected():
    try:
        discord_message({"channel": "random", "title": "test"})
    except ValueError as exc:
        assert "unsupported channel" in str(exc)
    else:
        raise AssertionError("Expected unsupported channel to be rejected")
