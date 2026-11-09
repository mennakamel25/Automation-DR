"""CRP backend: small REST API used to exercise the web -> api -> database path.

Design points that matter for disaster recovery:
  * /healthz        liveness only, never touches the database (safe for load balancers).
  * /readyz         checks the database (used by validation after recovery).
  * DB connection   multi-host libpq string with target_session_attrs=read-write, so the
                    client always lands on the current writable PostgreSQL primary
                    (Patroni failover needs no VIP and no DNS change).
  * generation guard  every DR failover bumps `failover_generation`. A node that still
                    holds an older generation than the database refuses writes, which
                    stops a stale/fenced API tier from writing after a failover.
"""
import logging
import os
import socket
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

log = logging.getLogger("crp.api")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))

SITE = os.getenv("CRP_SITE", "unknown")      # "primary" or "dr" (set by crp-boot.sh from the region we run in)
REGION = os.getenv("CRP_REGION", "unknown")
ZONE = os.getenv("CRP_ZONE", "unknown")
NODE = os.getenv("CRP_NAME", socket.gethostname())
GENERATION_FILE = Path(os.getenv("CRP_GENERATION_FILE", "/etc/crp/generation"))

DB_HOSTS = os.getenv("DB_HOSTS", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "crp")
DB_USER = os.getenv("DB_USER", "crp_app")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id         BIGSERIAL PRIMARY KEY,
    title      TEXT NOT NULL,
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS dr_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO dr_meta (key, value) VALUES ('failover_generation', '1')
ON CONFLICT (key) DO NOTHING;
"""

_pool = None


def conninfo() -> str:
    return (
        f"host={DB_HOSTS} port={DB_PORT} dbname={DB_NAME} user={DB_USER} "
        f"password={DB_PASSWORD} target_session_attrs=read-write connect_timeout=3"
    )


def get_pool():
    global _pool
    if _pool is None:
        from psycopg_pool import ConnectionPool

        _pool = ConnectionPool(conninfo(), min_size=1, max_size=5, open=False, timeout=5)
        _pool.open(wait=False)
    return _pool


def run(sql: str, params: tuple = (), fetch: str = "none") -> Any:
    """Single place that talks to PostgreSQL (monkeypatched in tests)."""
    from psycopg.rows import dict_row

    with get_pool().connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, params)
            if fetch == "all":
                return cur.fetchall()
            if fetch == "one":
                return cur.fetchone()
            return None


def local_generation() -> int:
    try:
        return int(GENERATION_FILE.read_text().strip())
    except (OSError, ValueError):
        return 1


def db_generation() -> int:
    row = run("SELECT value FROM dr_meta WHERE key = 'failover_generation'", fetch="one")
    return int(row["value"]) if row else 1


def writes_allowed() -> bool:
    return local_generation() >= db_generation()


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        run(SCHEMA)
        log.info("schema ready")
    except Exception as exc:  # database may not be up yet; /readyz will report it
        log.warning("schema init deferred: %s", exc)
    yield


app = FastAPI(title="CRP API", version="1.0.0", lifespan=lifespan)


class ItemIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class ItemPatch(BaseModel):
    done: Optional[bool] = None
    title: Optional[str] = Field(default=None, min_length=1, max_length=200)


@app.get("/healthz")
def healthz():
    return {"status": "ok", "node": NODE}


@app.get("/readyz")
def readyz():
    try:
        row = run("SELECT pg_is_in_recovery() AS standby", fetch="one")
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}")
    if row["standby"]:
        raise HTTPException(status_code=503, detail="connected to a standby, no writable primary")
    return {"status": "ready", "writable": writes_allowed()}


@app.get("/api/info")
def info():
    data = {
        "site": SITE,
        "region": REGION,
        "zone": ZONE,
        "node": NODE,
        "local_generation": local_generation(),
    }
    try:
        row = run("SELECT inet_server_addr()::text AS db_host, pg_is_in_recovery() AS standby", fetch="one")
        data.update(db_host=row["db_host"], db_standby=row["standby"], db_generation=db_generation(), db_ok=True)
        data["writes_allowed"] = writes_allowed()
    except Exception as exc:
        data.update(db_ok=False, db_error=str(exc)[:200], writes_allowed=False)
    return data


@app.get("/api/items")
def list_items():
    try:
        return run("SELECT id, title, done, created_at FROM items ORDER BY id DESC LIMIT 100", fetch="all")
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}")


def _guard():
    try:
        if not writes_allowed():
            raise HTTPException(status_code=503, detail="stale failover generation: writes refused")
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}")


@app.post("/api/items", status_code=201)
def create_item(item: ItemIn):
    _guard()
    row = run(
        "INSERT INTO items (title) VALUES (%s) RETURNING id, title, done, created_at",
        (item.title,),
        fetch="one",
    )
    return row


@app.patch("/api/items/{item_id}")
def update_item(item_id: int, patch: ItemPatch):
    _guard()
    row = run(
        "UPDATE items SET done = COALESCE(%s, done), title = COALESCE(%s, title) "
        "WHERE id = %s RETURNING id, title, done, created_at",
        (patch.done, patch.title, item_id),
        fetch="one",
    )
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    return row


@app.delete("/api/items/{item_id}", status_code=204)
def delete_item(item_id: int):
    _guard()
    run("DELETE FROM items WHERE id = %s", (item_id,))
