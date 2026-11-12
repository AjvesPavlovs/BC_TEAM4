"""PostgreSQL connection helpers: local DATABASE_URL or RDS-managed secret.

The AWS-managed RDS password stays in Secrets Manager and never enters Terraform
state or an ECS task-definition environment variable. boto3 uses the ECS task
role's temporary credentials. Restart the task after rotating the DB password.
"""
from __future__ import annotations

import json
import os
from contextlib import contextmanager
from functools import lru_cache
from typing import Any, Iterator


@lru_cache(maxsize=1)
def _rds_conninfo() -> str:
    import boto3
    from psycopg.conninfo import make_conninfo

    secret_arn = os.environ["RDS_SECRET_ARN"]
    region = os.environ.get("AWS_REGION", "eu-west-1")
    response = boto3.client("secretsmanager", region_name=region).get_secret_value(
        SecretId=secret_arn
    )
    credentials = json.loads(response["SecretString"])
    return make_conninfo(
        "",
        host=os.environ["RDS_HOST"],
        port=os.environ.get("RDS_PORT", "5432"),
        dbname=os.environ.get("RDS_DATABASE", "slicesip"),
        user=credentials["username"],
        password=credentials["password"],
        sslmode="require",
    )


def database_url() -> str:
    """Prefer local DSN; ECS uses RDS-managed Secrets Manager credentials."""
    local_dsn = os.environ.get("DATABASE_URL")
    if local_dsn:
        return local_dsn
    if os.environ.get("RDS_SECRET_ARN"):
        return _rds_conninfo()
    raise RuntimeError("DATABASE_URL or RDS_SECRET_ARN is required")


@contextmanager
def get_connection() -> Iterator[Any]:
    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover - depends on deployment image
        raise RuntimeError("psycopg is required; install backend/requirements.txt") from exc

    connection = psycopg.connect(database_url())
    try:
        yield connection
    finally:
        connection.close()
