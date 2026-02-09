#!/usr/bin/env python3
import hashlib
import json
import os
import time
from pathlib import Path
from typing import Dict, Optional
from urllib.parse import urlparse, urlunparse

import httpx
import yaml
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

BACKEND_URL = os.getenv("LLAMA_SERVER_BACKEND_URL", "http://127.0.0.1:8002")
BACKEND_API_KEY = os.getenv("LLAMA_SERVER_API_KEY", "")
ROUTES_FILE = os.getenv("LLAMA_PROXY_ROUTES_FILE", str(ROOT_DIR / "config" / "proxy_routes.yaml"))
ROUTE_HOST_OVERRIDE = os.getenv("LLAMA_PROXY_ROUTE_HOST", "")
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


def _load_routes() -> Dict[str, str]:
    routes: Dict[str, str] = {}
    path = Path(ROUTES_FILE)
    if not path.exists():
        return routes
    data = yaml.safe_load(path.read_text()) or {}
    for item in data.get("routes", []):
        model = (item.get("model") or "").strip()
        url = (item.get("backend_url") or "").strip()
        if model and url:
            if ROUTE_HOST_OVERRIDE:
                parsed = urlparse(url)
                url = urlunparse(
                    (parsed.scheme, f"{ROUTE_HOST_OVERRIDE}:{parsed.port}" if parsed.port else ROUTE_HOST_OVERRIDE,
                     parsed.path, parsed.params, parsed.query, parsed.fragment)
                )
            routes[model] = url
    return routes


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

    routes = _load_routes()
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

    if routes:
        if path == "v1/models":
            async with httpx.AsyncClient(timeout=30) as client:
                data = []
                seen = set()
                for route_model, route_url in routes.items():
                    route = f"{route_url.rstrip('/')}/v1/models"
                    try:
                        resp = await client.get(
                            route,
                            headers={"authorization": f"Bearer {BACKEND_API_KEY}"} if BACKEND_API_KEY else None,
                        )
                        if resp.status_code == 200:
                            payload = resp.json()
                            for item in payload.get("data", []):
                                model_id = item.get("id")
                                if model_id and model_id not in seen:
                                    seen.add(model_id)
                                    data.append(item)
                    except Exception:
                        continue
                return {"object": "list", "data": data}
        else:
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                model = payload.get("model")
                if model and model in routes:
                    url = f"{routes[model].rstrip('/')}/{path}"
            except Exception:
                pass

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
