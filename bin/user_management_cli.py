#!/usr/bin/env python3
"""
User management CLI for Llamaserve (Postgres-backed API keys).

Examples:
  ./bin/user_management_cli.sh init-db
  ./bin/user_management_cli.sh create-user --username alice
  ./bin/user_management_cli.sh rotate-key --username alice
  ./bin/user_management_cli.sh list-users
"""

import argparse
import hashlib
import os
import secrets
import sys
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:
    print("Missing dependency 'python-dotenv'. Run ./bin/bootstrap_user_cli.sh first.")
    raise SystemExit(1)

import psycopg2


ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / "runtime" / "config.env")


def _get_db_url() -> str:
    db_url = os.getenv("LLAMA_SERVER_DATABASE_URL") or os.getenv("DATABASE_URL")
    if db_url:
        return db_url
    user = os.getenv("POSTGRES_USER", "user")
    password = os.getenv("POSTGRES_PASSWORD", "pass")
    db = os.getenv("POSTGRES_DB", "vectordb")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"


DB_URL = _get_db_url()
USERS_TABLE = os.getenv("LLAMA_SERVER_USERS_TABLE", "llama_users")


def _hash_key(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _connect():
    return psycopg2.connect(DB_URL)


def _ensure_table():
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
    """
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(create_sql)


def cmd_init_db(_args):
    _ensure_table()
    print("DB initialized.")


def cmd_create_user(args):
    _ensure_table()
    token = args.api_key or secrets.token_hex(32)
    token_hash = _hash_key(token)
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"INSERT INTO {USERS_TABLE} (username, api_key_hash, is_active) VALUES (%s, %s, TRUE)",
                (args.username, token_hash),
            )
    print(f"User created: {args.username}")
    print(f"API key (store securely): {token}")


def cmd_rotate_key(args):
    _ensure_table()
    token = secrets.token_hex(32)
    token_hash = _hash_key(token)
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"UPDATE {USERS_TABLE} SET api_key_hash=%s WHERE username=%s",
                (token_hash, args.username),
            )
            if cur.rowcount == 0:
                print("User not found.")
                return
    print(f"API key rotated for: {args.username}")
    print(f"New API key (store securely): {token}")


def cmd_activate(args):
    _ensure_table()
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"UPDATE {USERS_TABLE} SET is_active=TRUE WHERE username=%s",
                (args.username,),
            )
    print(f"Activated: {args.username}")


def cmd_deactivate(args):
    _ensure_table()
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"UPDATE {USERS_TABLE} SET is_active=FALSE WHERE username=%s",
                (args.username,),
            )
    print(f"Deactivated: {args.username}")


def cmd_delete(args):
    _ensure_table()
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(f"DELETE FROM {USERS_TABLE} WHERE username=%s", (args.username,))
    print(f"Deleted (if existed): {args.username}")


def cmd_list(_args):
    _ensure_table()
    with _connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT username, is_active, created_at FROM {USERS_TABLE} ORDER BY created_at ASC"
            )
            rows = cur.fetchall()
    for username, active, created_at in rows:
        print(f"{username} | active={active} | created_at={created_at}")


def main():
    parser = argparse.ArgumentParser(description="Llamaserve user management")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init-db", help="Initialize users table")
    p_init.set_defaults(func=cmd_init_db)

    p_create = sub.add_parser("create-user", help="Create a user (generates API key)")
    p_create.add_argument("--username", required=True)
    p_create.add_argument("--api-key", required=False, help="Provide your own API key")
    p_create.set_defaults(func=cmd_create_user)

    p_rotate = sub.add_parser("rotate-key", help="Rotate API key for a user")
    p_rotate.add_argument("--username", required=True)
    p_rotate.set_defaults(func=cmd_rotate_key)

    p_activate = sub.add_parser("activate-user", help="Activate a user")
    p_activate.add_argument("--username", required=True)
    p_activate.set_defaults(func=cmd_activate)

    p_deactivate = sub.add_parser("deactivate-user", help="Deactivate a user")
    p_deactivate.add_argument("--username", required=True)
    p_deactivate.set_defaults(func=cmd_deactivate)

    p_delete = sub.add_parser("delete-user", help="Delete a user")
    p_delete.add_argument("--username", required=True)
    p_delete.set_defaults(func=cmd_delete)

    p_list = sub.add_parser("list-users", help="List users")
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
