"""Apply the idempotent SQL schema to the configured PostgreSQL database."""
from pathlib import Path

from database import get_connection


def main() -> None:
    schema = Path(__file__).with_name("schema.sql").read_text(encoding="utf-8")
    with get_connection() as connection:
        with connection.cursor() as cursor:
            # The schema contains independent DDL statements. Execute them
            # individually to avoid driver-specific multi-statement behavior.
            for statement in schema.split(";"):
                if statement.strip():
                    cursor.execute(statement)
        connection.commit()
    print("Slice & Sip database schema is up to date.")


if __name__ == "__main__":
    main()
