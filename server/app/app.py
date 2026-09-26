from __future__ import annotations

import os
from decimal import Decimal

import psycopg
from flask import Flask, jsonify, request
from psycopg.rows import dict_row


app = Flask(__name__)


def database_url() -> str:
    value = os.environ.get("DATABASE_URL", "").strip()
    if not value:
        raise RuntimeError("DATABASE_URL is not configured")
    return value


def connection() -> psycopg.Connection:
    return psycopg.connect(database_url(), row_factory=dict_row, connect_timeout=3)


def serialize_order(row: dict) -> dict:
    result = dict(row)
    amount = result.get("amount")
    if isinstance(amount, Decimal):
        result["amount"] = format(amount, ".2f")
    created_at = result.get("created_at")
    if created_at is not None:
        result["created_at"] = created_at.isoformat()
    return result


@app.get("/")
def index():
    return jsonify({"service": "orders-api", "endpoints": ["/health", "/orders"]})


@app.get("/health")
def health():
    with connection() as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT current_database() AS database, 1 AS ok")
            row = cursor.fetchone()
    return jsonify({"status": "ok", "database": row["database"]})


@app.get("/orders")
def list_orders():
    with connection() as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT id, customer, amount, status, created_at FROM orders ORDER BY id"
            )
            rows = cursor.fetchall()
    return jsonify([serialize_order(row) for row in rows])


@app.post("/orders")
def create_order():
    payload = request.get_json(silent=True) or {}
    customer = str(payload.get("customer", "")).strip()
    status = str(payload.get("status", "pending")).strip().lower()
    try:
        amount = Decimal(str(payload.get("amount", "")))
    except Exception:
        return jsonify({"error": "amount must be a positive decimal"}), 400

    if not customer:
        return jsonify({"error": "customer is required"}), 400
    if amount <= 0:
        return jsonify({"error": "amount must be positive"}), 400
    if status not in {"pending", "paid", "cancelled"}:
        return jsonify({"error": "invalid status"}), 400

    with connection() as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO orders (customer, amount, status)
                VALUES (%s, %s, %s)
                RETURNING id, customer, amount, status, created_at
                """,
                (customer, amount, status),
            )
            row = cursor.fetchone()
        conn.commit()
    return jsonify(serialize_order(row)), 201


@app.errorhandler(Exception)
def unhandled_error(error: Exception):
    app.logger.exception("request failed")
    return jsonify({"error": "internal service error"}), 500
