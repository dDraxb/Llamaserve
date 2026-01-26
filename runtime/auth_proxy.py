#!/usr/bin/env python3
import hashlib
import os
import time
from pathlib import Path
from typing import Dict, Optional

import httpx
from psycopg2 import pool
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
}


def _env(name: str, default: Optional[str] = None) -> str:
    value = os.getenv(name, default)
    if value is None:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


ROOT_DIR = Path(__file__).resolve().parents[1]


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_env_file(ROOT_DIR / "runtime" / "config.env")
_load_env_file(ROOT_DIR / ".env")

BACKEND_URL = os.getenv("LLAMA_SERVER_BACKEND_URL", "http://127.0.0.1:8000")
BACKEND_API_KEY = os.getenv("LLAMA_SERVER_API_KEY", "")
USERS_TABLE = os.getenv("LLAMA_SERVER_USERS_TABLE", "llama_users")
REQUESTS_TABLE = os.getenv("LLAMA_SERVER_REQUESTS_TABLE", "llama_requests")
RATE_LIMIT = int(os.getenv("LLAMA_PROXY_RATE_LIMIT", "60"))
RATE_WINDOW_SECONDS = int(os.getenv("LLAMA_PROXY_RATE_WINDOW_SECONDS", "60"))

def _get_db_url() -> Optional[str]:
    user = os.getenv("POSTGRES_AUTH_USER")
    password = os.getenv("POSTGRES_AUTH_PASSWORD")
    db = os.getenv("POSTGRES_AUTH_DB")
    host = os.getenv("POSTGRES_AUTH_HOST", "localhost")
    port = os.getenv("POSTGRES_AUTH_PORT", "5432")
    if user and password and db:
        return f"postgresql://{user}:{password}@{host}:{port}/{db}"
    return None


DB_URL = _get_db_url()
if not DB_URL:
    raise RuntimeError("Missing DB config. Set POSTGRES_AUTH_* in .env.")

app = FastAPI()
db_pool: pool.SimpleConnectionPool


def _hash_key(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _filter_headers(headers: Dict[str, str]) -> Dict[str, str]:
    return {k: v for k, v in headers.items() if k.lower() not in HOP_BY_HOP_HEADERS}


def _ensure_table() -> None:
    create_sql = f"""
    CREATE TABLE IF NOT EXISTS {USERS_TABLE} (
        id SERIAL PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        api_key_hash TEXT NOT NULL,
        is_active BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS {USERS_TABLE}_api_key_hash_idx
        ON {USERS_TABLE} (api_key_hash);

    CREATE TABLE IF NOT EXISTS {REQUESTS_TABLE} (
        id BIGSERIAL PRIMARY KEY,
        username TEXT NOT NULL,
        path TEXT NOT NULL,
        status_code INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        request_bytes BIGINT NOT NULL DEFAULT 0,
        response_bytes BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS {REQUESTS_TABLE}_username_created_at_idx
        ON {REQUESTS_TABLE} (username, created_at);
    """
    conn = db_pool.getconn()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(create_sql)
                cur.execute(
                    f"ALTER TABLE {REQUESTS_TABLE} ADD COLUMN IF NOT EXISTS duration_ms INTEGER NOT NULL DEFAULT 0"
                )
                cur.execute(
                    f"ALTER TABLE {REQUESTS_TABLE} ADD COLUMN IF NOT EXISTS request_bytes BIGINT NOT NULL DEFAULT 0"
                )
                cur.execute(
                    f"ALTER TABLE {REQUESTS_TABLE} ADD COLUMN IF NOT EXISTS response_bytes BIGINT NOT NULL DEFAULT 0"
                )
    finally:
        db_pool.putconn(conn)


def _get_user_for_token(token: str) -> Optional[str]:
    token_hash = _hash_key(token)
    query = f"SELECT username, is_active FROM {USERS_TABLE} WHERE api_key_hash = %s LIMIT 1"
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(query, (token_hash,))
            row = cur.fetchone()
            if not row:
                return None
            username, is_active = row
            if not is_active:
                return None
            return username
    finally:
        db_pool.putconn(conn)


def _rate_limited(username: str) -> bool:
    query = f"""
        SELECT COUNT(*)
        FROM {REQUESTS_TABLE}
        WHERE username = %s
          AND created_at >= NOW() - INTERVAL '%s seconds'
    """
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(query, (username, RATE_WINDOW_SECONDS))
            count = cur.fetchone()[0]
            return count >= RATE_LIMIT
    finally:
        db_pool.putconn(conn)


def _log_request(
    username: str,
    path: str,
    status_code: int,
    duration_ms: int = 0,
    request_bytes: int = 0,
    response_bytes: int = 0,
) -> None:
    insert_sql = f"""
        INSERT INTO {REQUESTS_TABLE} (username, path, status_code, duration_ms, request_bytes, response_bytes)
        VALUES (%s, %s, %s, %s, %s, %s)
    """
    conn = db_pool.getconn()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    insert_sql,
                    (username, path, status_code, duration_ms, request_bytes, response_bytes),
                )
    finally:
        db_pool.putconn(conn)


def _extract_bearer_token(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = auth.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    return token


@app.on_event("startup")
def _startup() -> None:
    global db_pool
    db_pool = pool.SimpleConnectionPool(1, 5, dsn=DB_URL)
    _ensure_table()


@app.on_event("shutdown")
def _shutdown() -> None:
    if "db_pool" in globals() and db_pool:
        db_pool.closeall()


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(path: str, request: Request):
    token = _extract_bearer_token(request)
    username = _get_user_for_token(token)
    if not username:
        raise HTTPException(status_code=401, detail="Invalid or inactive token")

    url = f"{BACKEND_URL.rstrip('/')}/{path}"
    headers = _filter_headers(dict(request.headers))
    headers["x-llama-user"] = username
    if BACKEND_API_KEY:
        headers["authorization"] = f"Bearer {BACKEND_API_KEY}"
    else:
        headers.pop("authorization", None)

    body = await request.body()
    request_bytes = len(body)
    params = request.query_params

    if _rate_limited(username):
        _log_request(
            username,
            f"/{path}",
            429,
            duration_ms=0,
            request_bytes=request_bytes,
            response_bytes=0,
        )
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    start_time = time.monotonic()
    client = httpx.AsyncClient(timeout=None)
    try:
        resp = await client.send(
            client.build_request(
                request.method,
                url,
                params=params,
                headers=headers,
                content=body,
            ),
            stream=True,
        )
    except httpx.RequestError:
        await client.aclose()
        _log_request(username, f"/{path}", 502, request_bytes=request_bytes)
        raise HTTPException(status_code=502, detail="Upstream connection failed")

    response_bytes = 0
    resp_headers = _filter_headers(dict(resp.headers))

    async def _stream():
        nonlocal response_bytes
        try:
            async for chunk in resp.aiter_bytes():
                response_bytes += len(chunk)
                yield chunk
        finally:
            duration_ms = int((time.monotonic() - start_time) * 1000)
            _log_request(
                username,
                f"/{path}",
                resp.status_code,
                duration_ms=duration_ms,
                request_bytes=request_bytes,
                response_bytes=response_bytes,
            )
            await resp.aclose()
            await client.aclose()

    return StreamingResponse(
        _stream(),
        status_code=resp.status_code,
        headers=resp_headers,
        media_type=resp.headers.get("content-type"),
    )
