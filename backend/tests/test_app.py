from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import app as api


class FakeCursor:
    def __init__(self, connection):
        self.connection = connection
        self.result = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def execute(self, query, params=None):
        normalized = " ".join(query.split()).lower()
        if "select nextval('order_ticket_seq')" in normalized:
            self.connection.order_seq += 1
            self.result = (self.connection.order_seq,)
        elif "select nextval('invoice_ticket_seq')" in normalized:
            self.connection.invoice_seq += 1
            self.result = (self.connection.invoice_seq,)
        elif "select nextval('support_ticket_seq')" in normalized:
            self.connection.support_seq += 1
            self.result = (self.connection.support_seq,)
        elif "where o.idempotency_key" in normalized:
            record = self.connection.result_by_key.get(params[0])
            self.result = (
                (record["id"], record["order_ticket"], record["invoice_ticket"], record["total"])
                if record and record.get("invoice_ticket") else None
            )
        elif "select id from orders" in normalized:
            self.result = self.connection.orders_by_ticket.get(params[0])
        elif "insert into orders" in normalized:
            self.connection.order_id += 1
            self.connection.orders_by_ticket[params[0]] = (self.connection.order_id,)
            self.connection.result_by_key[params[1]] = {
                "id": self.connection.order_id,
                "order_ticket": params[0],
                "total": params[4],
            }
            self.result = (self.connection.order_id,)
        elif "insert into invoices" in normalized:
            self.connection.result_by_key[next(
                key for key, value in self.connection.result_by_key.items()
                if value["id"] == params[1]
            )]["invoice_ticket"] = params[0]
            self.result = None
        elif "insert into support_tickets" in normalized:
            self.connection.support_inserts += 1
            self.result = None
        elif "insert into notification_outbox" in normalized:
            self.connection.outbox_inserts += 1
            self.result = None
        elif normalized == "select 1":
            self.result = (1,)
        else:
            raise AssertionError(f"Unexpected SQL in test: {normalized}")

    def fetchone(self):
        return self.result


class FakeConnection:
    def __init__(self):
        self.order_seq = 0
        self.invoice_seq = 0
        self.support_seq = 0
        self.order_id = 0
        self.orders_by_ticket = {}
        self.result_by_key = {}
        self.support_inserts = 0
        self.outbox_inserts = 0

    def cursor(self):
        return FakeCursor(self)

    class _Transaction:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    def transaction(self):
        return self._Transaction()


@pytest.fixture
def client_and_db():
    fake_db = FakeConnection()
    api.app.dependency_overrides[api.get_db_connection] = lambda: fake_db
    with TestClient(api.app) as client:
        yield client, fake_db
    api.app.dependency_overrides.clear()


def test_health_endpoint(client_and_db):
    client, _ = client_and_db
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_order_uses_database_ticket_sequences_and_creates_invoice_events(client_and_db):
    client, fake_db = client_and_db
    response = client.post(
        "/api/orders",
        headers={"Idempotency-Key": "test-order-001"},
        json={
            "customerName": "Demo Customer",
            "items": [{"id": 1, "quantity": 2}],
        },
    )
    assert response.status_code == 201
    data = response.json()
    assert data["order_ticket"].startswith("ORD-")
    assert data["invoice_ticket"].startswith("INV-")
    assert data["total_amount"] == "25.98"
    assert data["notification_status"] == "queued_for_publication"
    assert fake_db.outbox_inserts == 2


def test_browser_cannot_override_product_price(client_and_db):
    client, _ = client_and_db
    response = client.post(
        "/api/orders",
        json={
            "customerName": "Demo Customer",
            "items": [{"id": 1, "quantity": 1, "price": 0.01}],
        },
    )
    assert response.status_code == 422


def test_unknown_product_is_rejected(client_and_db):
    client, _ = client_and_db
    response = client.post(
        "/api/orders",
        json={"customerName": "Demo Customer", "items": [{"id": 999, "quantity": 1}]},
    )
    assert response.status_code == 422


def test_support_request_generates_one_ticket_and_event(client_and_db):
    client, fake_db = client_and_db
    response = client.post(
        "/api/support",
        json={
            "customerName": "Demo Customer",
            "message": "Where is my order?",
        },
    )
    assert response.status_code == 201
    assert response.json()["support_ticket"].startswith("SUP-")
    assert fake_db.support_inserts == 1
    assert fake_db.outbox_inserts == 1


def test_support_request_rejects_unknown_related_order(client_and_db):
    client, fake_db = client_and_db
    response = client.post(
        "/api/support",
        json={
            "customerName": "Demo Customer",
            "orderTicket": "ORD-2026-999999",
            "message": "Where is my order?",
        },
    )
    assert response.status_code == 404


def test_order_idempotency_returns_existing_order_without_duplicate_events(client_and_db):
    client, fake_db = client_and_db
    payload = {"customerName": "Demo Customer", "items": [{"id": 3, "quantity": 2}]}
    headers = {"Idempotency-Key": "replay-safe-test"}
    first = client.post("/api/orders", headers=headers, json=payload)
    outbox_count_after_first = fake_db.outbox_inserts
    second = client.post("/api/orders", headers=headers, json=payload)
    assert first.status_code == 201
    assert second.status_code == 201
    assert second.json()["replayed"] is True
    assert second.json()["order_ticket"] == first.json()["order_ticket"]
    assert second.json()["invoice_ticket"] == first.json()["invoice_ticket"]
    assert fake_db.outbox_inserts == outbox_count_after_first == 2
