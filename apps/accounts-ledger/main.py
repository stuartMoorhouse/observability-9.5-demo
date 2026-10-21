"""accounts-ledger: balances and ledger entries in Postgres.

No OpenTelemetry SDK in the image: EDOT Python is injected by the OTel Operator and
auto-instruments FastAPI and psycopg (DB spans).
"""

import os
import threading
import time
from contextlib import asynccontextmanager
from decimal import Decimal
from pathlib import Path

import psycopg
from psycopg.conninfo import make_conninfo
from fastapi import FastAPI, HTTPException
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

from logging_setup import configure

log = configure("accounts-ledger")

FAULT_DIR = Path(os.getenv("FAULT_DIR", "/etc/fault"))
CURRENCIES = ["EUR", "EUR", "EUR", "GBP", "USD", "SEK"]
SEED_ACCOUNTS = int(os.getenv("SEED_ACCOUNTS", "50"))


def conninfo() -> str:
    return make_conninfo(
        host=os.getenv("PGHOST", "postgres"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "ledger"),
        user=os.getenv("PGUSER", "ledger"),
        password=os.getenv("PGPASSWORD", ""),
        connect_timeout=5,
        application_name="accounts-ledger",
    )


class FaultConfig:
    """Reads /etc/fault/SLOW_DB, cached for 5 s."""

    def __init__(self, directory: Path):
        self._file = directory / "SLOW_DB"
        self._value = False
        self._read_at = 0.0
        self._lock = threading.Lock()

    def slow_db(self) -> bool:
        now = time.monotonic()
        with self._lock:
            if now - self._read_at > 5:
                try:
                    new = self._file.read_text().strip().lower() == "true"
                except OSError:
                    new = False
                if new != self._value:
                    log.info("Fault config changed: SLOW_DB=%s", new)
                self._value = new
                self._read_at = now
            return self._value


faults = FaultConfig(FAULT_DIR)
pool: ConnectionPool | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id          TEXT PRIMARY KEY,
    owner       TEXT NOT NULL,
    currency    CHAR(3) NOT NULL,
    balance     NUMERIC(14, 2) NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS ledger_entries (
    id          BIGSERIAL PRIMARY KEY,
    account_id  TEXT NOT NULL REFERENCES accounts(id),
    direction   TEXT NOT NULL CHECK (direction IN ('debit', 'credit')),
    amount      NUMERIC(14, 2) NOT NULL,
    reference   TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def init_db(max_wait_s: int = 300) -> None:
    deadline = time.monotonic() + max_wait_s
    attempt = 0
    while True:
        attempt += 1
        try:
            with psycopg.connect(conninfo(), autocommit=True) as conn:
                conn.execute(SCHEMA)
                with conn.cursor() as cur:
                    cur.executemany(
                        "INSERT INTO accounts (id, owner, currency, balance) VALUES (%s, %s, %s, %s) "
                        "ON CONFLICT (id) DO NOTHING",
                        [
                            (f"ACC-{1001 + i}", f"Customer {1001 + i}", CURRENCIES[i % len(CURRENCIES)],
                             Decimal("1000000.00"))
                            for i in range(SEED_ACCOUNTS)
                        ],
                    )
            log.info("Database ready (schema + %d seed accounts) after %d attempt(s)", SEED_ACCOUNTS, attempt)
            return
        except psycopg.OperationalError as exc:
            if time.monotonic() > deadline:
                raise
            log.warning("Database not ready (attempt %d): %s", attempt, exc)
            time.sleep(3)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global pool
    init_db()
    pool = ConnectionPool(conninfo(), min_size=1, max_size=10, open=True)
    yield
    pool.close()


app = FastAPI(title="accounts-ledger", lifespan=lifespan)


class Posting(BaseModel):
    accountId: str = Field(pattern=r"^[A-Z]{3}-\d{4}$")
    amount: Decimal = Field(gt=0)
    reference: str = Field(min_length=1, max_length=64)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/ledger/accounts/{account_id}/balance")
def balance(account_id: str):
    assert pool is not None
    if faults.slow_db():
        # Deliberately slow statement: shows up as a long DB span in the trace.
        sql = "SELECT balance, currency, pg_sleep(0.8) FROM accounts WHERE id = %s"
    else:
        sql = "SELECT balance, currency FROM accounts WHERE id = %s"
    with pool.connection() as conn:
        row = conn.execute(sql, (account_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="account not found")
    return {"accountId": account_id, "balance": float(row[0]), "currency": row[1].strip()}


def _post(entry: Posting, direction: str) -> dict:
    assert pool is not None
    sign = -1 if direction == "debit" else 1
    with pool.connection() as conn:
        with conn.transaction():
            if faults.slow_db():
                # Unindexed scan of the ledger plus a sleep to make the DB the bottleneck.
                conn.execute(
                    "SELECT count(*), pg_sleep(0.8) FROM ledger_entries WHERE reference LIKE %s",
                    (f"%{entry.reference[-6:]}%",),
                )
            row = conn.execute(
                "UPDATE accounts SET balance = balance + %s WHERE id = %s RETURNING balance, currency",
                (sign * entry.amount, entry.accountId),
            ).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="account not found")
            if row[0] < 0:
                raise HTTPException(status_code=409, detail="insufficient funds")
            conn.execute(
                "INSERT INTO ledger_entries (account_id, direction, amount, reference) VALUES (%s, %s, %s, %s)",
                (entry.accountId, direction, entry.amount, entry.reference),
            )
    log.info(
        "Posted %s of %s to %s",
        direction,
        entry.amount,
        entry.accountId,
        extra={"fields": {"ledger.reference": entry.reference, "ledger.direction": direction}},
    )
    return {"accountId": entry.accountId, "direction": direction, "balance": float(row[0]), "currency": row[1].strip()}


@app.post("/ledger/debit")
def debit(entry: Posting):
    return _post(entry, "debit")


@app.post("/ledger/credit")
def credit(entry: Posting):
    return _post(entry, "credit")
