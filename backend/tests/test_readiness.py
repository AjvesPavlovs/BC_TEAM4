from unittest.mock import MagicMock

from fastapi.testclient import TestClient

import app as api


def test_ready_when_database_is_connected(monkeypatch):
    connection = MagicMock()
    monkeypatch.setattr(api, "get_connection", lambda: connection)

    response = TestClient(api.app).get("/ready")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ready",
        "database": "connected",
    }

    cursor = (
        connection.__enter__
        .return_value.cursor.return_value
        .__enter__.return_value
    )
    cursor.execute.assert_called_once_with("SELECT 1")


def test_not_ready_when_database_connection_fails(monkeypatch):
    def unavailable():
        raise ConnectionError("Database unavailable")

    monkeypatch.setattr(api, "get_connection", unavailable)

    response = TestClient(api.app).get("/ready")

    assert response.status_code == 503
    assert response.json() == {
        "detail": "Database is not ready",
    }
