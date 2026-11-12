"""Tests for local vs AWS-managed database credential discovery."""
from __future__ import annotations

import json
import sys
import types

import pytest

import database


def test_local_database_url(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://local:pass@localhost:5432/db")
    monkeypatch.delenv("RDS_SECRET_ARN", raising=False)
    assert database.database_url() == "postgresql://local:pass@localhost:5432/db"


def test_missing_configuration(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("RDS_SECRET_ARN", raising=False)
    with pytest.raises(RuntimeError, match="DATABASE_URL or RDS_SECRET_ARN"):
        database.database_url()


def test_rds_managed_secret(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("RDS_SECRET_ARN", "arn:aws:secretsmanager:fake:secret:slicesip")
    monkeypatch.setenv("RDS_HOST", "private-db.example.internal")
    monkeypatch.setenv("RDS_PORT", "5432")
    monkeypatch.setenv("RDS_DATABASE", "slicesip")
    database._rds_conninfo.cache_clear()

    class FakeClient:
        def get_secret_value(self, SecretId):
            assert SecretId == "arn:aws:secretsmanager:fake:secret:slicesip"
            return {"SecretString": json.dumps({"username": "svc", "password": "my pass'word"})}

    fake_boto = types.ModuleType("boto3")
    fake_boto.client = lambda *args, **kwargs: FakeClient()
    monkeypatch.setitem(sys.modules, "boto3", fake_boto)

    # Unit tests can run without installed production DB driver.
    fake_psycopg = types.ModuleType("psycopg")
    fake_conninfo = types.ModuleType("psycopg.conninfo")
    def make_conninfo(_base, **opts):
        assert opts["password"] == "my pass'word"
        return " ".join(f"{k}={v}" for k, v in opts.items() if k != "password")
    fake_conninfo.make_conninfo = make_conninfo
    monkeypatch.setitem(sys.modules, "psycopg", fake_psycopg)
    monkeypatch.setitem(sys.modules, "psycopg.conninfo", fake_conninfo)

    value = database.database_url()
    assert "host=private-db.example.internal" in value
    assert "dbname=slicesip" in value
    assert "user=svc" in value
    assert "sslmode=require" in value
    database._rds_conninfo.cache_clear()
