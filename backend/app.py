"""Slice & Sip API: authoritative orders, invoices and support ticket IDs."""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from database import get_connection


def get_db_connection():
    """FastAPI dependency that opens and closes one database connection."""
    with get_connection() as connection:
        yield connection

app = FastAPI(
    title="Slice & Sip API",
    version="1.0.0",
    description="Order, invoice and customer-support API for the Slice & Sip demo.",
)

# Prices are authoritative here, not in the browser. The frontend sends product
# IDs and quantities only, so clients cannot change prices by editing requests.
CATALOG: dict[int, dict[str, Any]] = {
    1: {"name": "Artisanal Pepperoni Pizza", "price": Decimal("12.99")},
    2: {"name": "Raw Broccoli", "price": Decimal("8.99")},
    3: {"name": "Ginger Lemonade", "price": Decimal("4.99")},
}

ShortText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]


class OrderItem(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: int = Field(gt=0)
    quantity: int = Field(ge=1, le=50)


class OrderRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="forbid")
    customer_name: ShortText = Field(alias="customerName")
    items: list[OrderItem] = Field(min_length=1, max_length=20)


class SupportRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="forbid")
    customer_name: ShortText = Field(alias="customerName")
    order_ticket: str | None = Field(default=None, alias="orderTicket", max_length=32)
    message: str = Field(min_length=3, max_length=4000)


def _next_ticket(cursor: Any, sequence_name: str, prefix: str) -> str:
    # Sequence names are fixed constants selected by server code, never user input.
    cursor.execute(f"SELECT nextval('{sequence_name}')")
    sequence_value = int(cursor.fetchone()[0])
    year = datetime.now(timezone.utc).year
    return f"{prefix}-{year}-{sequence_value:06d}"


def _write_outbox(
    cursor: Any,
    event_type: str,
    channel: str,
    payload: dict[str, Any],
) -> None:
    event_id = str(uuid.uuid4())
    event = {
        "event_id": event_id,
        "event_type": event_type,
        "channel": channel,
        **payload,
    }
    cursor.execute(
        """INSERT INTO notification_outbox
           (event_id, event_type, channel, payload)
           VALUES (%s, %s, %s, %s::jsonb)""",
        (event_id, event_type, channel, json.dumps(event)),
    )


def _normalise_order_items(items: list[OrderItem]) -> tuple[list[dict[str, Any]], Decimal]:
    normalised: list[dict[str, Any]] = []
    total = Decimal("0.00")
    for item in items:
        product = CATALOG.get(item.id)
        if product is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"Unknown product ID: {item.id}",
            )
        line_total = product["price"] * item.quantity
        total += line_total
        normalised.append(
            {
                "id": item.id,
                "name": product["name"],
                "quantity": item.quantity,
                "unit_price": str(product["price"]),
                "line_total": str(line_total),
            }
        )
    return normalised, total.quantize(Decimal("0.01"))


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness endpoint; database readiness is checked separately."""
    return {"status": "ok", "service": "slice-sip-api"}


@app.get("/ready")
def readiness() -> dict[str, str]:
    """Report ready only when PostgreSQL is reachable."""
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()

        return {"status": "ready", "database": "connected"}
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail="Database is not ready",
        ) from exc


@app.post("/api/orders", status_code=status.HTTP_201_CREATED)
def create_order(
    request: OrderRequest,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    connection: Any = Depends(get_db_connection),
) -> dict[str, Any]:
    """Create one order and invoice atomically, then record both events."""
    key = (idempotency_key or str(uuid.uuid4())).strip()
    if not key or len(key) > 80:
        raise HTTPException(status_code=400, detail="Invalid Idempotency-Key")

    items, total = _normalise_order_items(request.items)

    try:
        with connection.transaction():
            with connection.cursor() as cursor:
                # Repeated request with the same key returns the original result.
                cursor.execute(
                    """SELECT o.id, o.ticket_number, i.ticket_number, o.total_amount
                       FROM orders o JOIN invoices i ON i.order_id = o.id
                       WHERE o.idempotency_key = %s""",
                    (key,),
                )
                existing = cursor.fetchone()
                if existing:
                    return {
                        "order_ticket": existing[1],
                        "invoice_ticket": existing[2],
                        "total_amount": str(existing[3]),
                        "currency": "USD",
                        "replayed": True,
                    }

                order_ticket = _next_ticket(cursor, "order_ticket_seq", "ORD")
                invoice_ticket = _next_ticket(cursor, "invoice_ticket_seq", "INV")
                cursor.execute(
                    """INSERT INTO orders
                       (ticket_number, idempotency_key, customer_name, items, total_amount, currency)
                       VALUES (%s, %s, %s, %s::jsonb, %s, 'USD')
                       RETURNING id""",
                    (
                        order_ticket,
                        key,
                        request.customer_name,
                        json.dumps(items),
                        total,
                    ),
                )
                order_id = int(cursor.fetchone()[0])
                cursor.execute(
                    """INSERT INTO invoices (ticket_number, order_id, total_amount, currency)
                       VALUES (%s, %s, %s, 'USD')""",
                    (invoice_ticket, order_id, total),
                )

                item_summary = "\n".join(
                    f"• {row['quantity']} × {row['name']}" for row in items
                )
                _write_outbox(
                    cursor,
                    "order.created",
                    "orders",
                    {
                        "title": "🛒 New order received",
                        "description": (
                            f"**Order:** `{order_ticket}`\n"
                            f"**Status:** Confirmed\n"
                            f"**Total:** ${total:.2f}\n"
                            f"**Items:**\n{item_summary}"
                        ),
                    },
                )
                _write_outbox(
                    cursor,
                    "invoice.created",
                    "invoices",
                    {
                        "title": "🧾 Invoice created",
                        "description": (
                            f"**Invoice:** `{invoice_ticket}`\n"
                            f"**Related order:** `{order_ticket}`\n"
                            f"**Amount:** ${total:.2f}\n"
                            "**Status:** Issued"
                        ),
                    },
                )

        return {
            "order_ticket": order_ticket,
            "invoice_ticket": invoice_ticket,
            "total_amount": str(total),
            "currency": "USD",
            "notification_status": "queued_for_publication",
        }
    except HTTPException:
        raise
    except Exception as exc:
        # Keep internal SQL/connection details out of public API responses.
        print(f"Order creation failed ({type(exc).__name__})")
        raise HTTPException(status_code=503, detail="Order could not be created") from exc


@app.post("/api/support", status_code=status.HTTP_201_CREATED)
def create_support_ticket(
    request: SupportRequest,
    connection: Any = Depends(get_db_connection),
) -> dict[str, str]:
    """Create one support conversation/ticket and one outbox event."""
    try:
        with connection.transaction():
            with connection.cursor() as cursor:
                related_order_id = None
                if request.order_ticket:
                    cursor.execute(
                        "SELECT id FROM orders WHERE ticket_number = %s",
                        (request.order_ticket.strip(),),
                    )
                    order = cursor.fetchone()
                    if order is None:
                        raise HTTPException(status_code=404, detail="Related order was not found")
                    related_order_id = int(order[0])

                support_ticket = _next_ticket(cursor, "support_ticket_seq", "SUP")
                cursor.execute(
                    """INSERT INTO support_tickets
                       (ticket_number, customer_name, related_order_id, message)
                       VALUES (%s, %s, %s, %s)""",
                    (
                        support_ticket,
                        request.customer_name,
                        related_order_id,
                        request.message.strip(),
                    ),
                )
                # Do not forward the customer's raw message to Discord. The ticket
                # reference is enough for the team to locate it in the application.
                _write_outbox(
                    cursor,
                    "support.created",
                    "support",
                    {
                        "title": "💬 New customer support request",
                        "description": (
                            f"**Ticket:** `{support_ticket}`\n"
                            f"**Related order:** `{request.order_ticket or 'Not specified'}`\n"
                            "**Status:** Open\n"
                            "A new customer message is waiting in the application."
                        ),
                    },
                )
        return {"support_ticket": support_ticket, "status": "received"}
    except HTTPException:
        raise
    except Exception as exc:
        print(f"Support ticket creation failed ({type(exc).__name__})")
        raise HTTPException(status_code=503, detail="Support request could not be saved") from exc
