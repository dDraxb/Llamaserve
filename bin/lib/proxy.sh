#!/usr/bin/env bash

is_proxy_running() {
  if [[ -f "$LLAMA_PROXY_PID_FILE" ]]; then
    local pid
    pid="$(cat "$LLAMA_PROXY_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    else
      rm -f "$LLAMA_PROXY_PID_FILE"
      return 1
    fi
  else
    return 1
  fi
}

ensure_proxy_deps() {
  "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1 || {
import importlib
for m in ("fastapi", "uvicorn", "httpx", "psycopg2"):
    importlib.import_module(m)
PY
    err "Missing proxy dependencies in venv."
    err "Run install: $RUNTIME_DIR/install.sh"
    exit 1
  }
}

ensure_db_url() {
  local env_file="$ROOT_DIR/.env"
  if [[ -f "$env_file" ]]; then
    local line key value
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^# ]] && continue
      [[ "$line" != *=* ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      key="$(trim "$key")"
      value="$(trim "$value")"
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      if [[ -n "$key" ]] && [[ -z "${!key:-}" ]]; then
        export "$key=$value"
      fi
    done < "$env_file"
  fi

  if [[ -n "${POSTGRES_AUTH_USER:-}" ]] && [[ -n "${POSTGRES_AUTH_PASSWORD:-}" ]] && [[ -n "${POSTGRES_AUTH_DB:-}" ]]; then
    local db_host="${POSTGRES_AUTH_HOST:-localhost}"
    local db_port="${POSTGRES_AUTH_PORT:-5432}"
    export LLAMA_SERVER_DATABASE_URL="postgresql://${POSTGRES_AUTH_USER}:${POSTGRES_AUTH_PASSWORD}@${db_host}:${db_port}/${POSTGRES_AUTH_DB}"
  fi

  if [[ -z "${LLAMA_SERVER_DATABASE_URL:-}" ]]; then
    err "Database URL not set. Set POSTGRES_AUTH_* in .env."
    exit 1
  fi
}

start_proxy() {
  if is_proxy_running; then
    err "Proxy already running. Use: $0 restart-proxy"
    exit 1
  fi

  local existing_pid
  existing_pid="$(find_pid_by_port "$LLAMA_PROXY_PORT")"
  if [[ -n "$existing_pid" ]]; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      if docker compose -f "$ROOT_DIR/docker-compose.yml" ps --status running proxy 2>/dev/null | grep -q "proxy"; then
        err "Port $LLAMA_PROXY_PORT is already used by docker-compose proxy."
        err "Stop it first with: docker compose stop proxy"
        err "Or use the Docker proxy directly and do not run: $0 start-proxy"
        exit 1
      fi
    fi
    err "Port $LLAMA_PROXY_PORT is already in use by PID $existing_pid."
    err "Free the port or change LLAMA_PROXY_PORT in runtime/config.env."
    exit 1
  fi

  ensure_venv_and_deps
  ensure_proxy_deps
  ensure_db_url
  mkdir -p "$LLAMA_SERVER_LOG_DIR"

  export LLAMA_SERVER_BACKEND_URL="${LLAMA_SERVER_BACKEND_URL:-http://127.0.0.1:$LLAMA_SERVER_PORT}"

  info "Starting auth proxy..."
  info "Backend: $LLAMA_SERVER_BACKEND_URL"
  info "Bind   : $LLAMA_PROXY_HOST"
  info "Port   : $LLAMA_PROXY_PORT"
  info "Log    : $PROXY_LOG_FILE"

  "$PYTHON_BIN" -m uvicorn auth_proxy:app \
    --app-dir "$RUNTIME_DIR" \
    --host "$LLAMA_PROXY_HOST" \
    --port "$LLAMA_PROXY_PORT" >>"$PROXY_LOG_FILE" 2>&1 &

  local started_pid="$!"
  echo "$started_pid" > "$LLAMA_PROXY_PID_FILE"
  sleep 0.25
  if ! kill -0 "$started_pid" 2>/dev/null; then
    err "Proxy exited early. Check log: $PROXY_LOG_FILE"
    tail -n 20 "$PROXY_LOG_FILE" >&2 || true
    rm -f "$LLAMA_PROXY_PID_FILE"
    exit 1
  fi
  info "Proxy started with PID $(cat "$LLAMA_PROXY_PID_FILE")"
}

stop_proxy() {
  if ! is_proxy_running; then
    info "Proxy is not running."
    return 0
  fi

  local pid
  pid="$(cat "$LLAMA_PROXY_PID_FILE")"
  info "Stopping proxy (PID $pid)..."
  kill "$pid" 2>/dev/null || true

  local i
  for i in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$LLAMA_PROXY_PID_FILE"
      info "Proxy stopped."
      return 0
    fi
    sleep 0.25
  done

  err "Proxy did not stop gracefully; sending SIGKILL."
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$LLAMA_PROXY_PID_FILE"
}

restart_proxy() {
  stop_proxy
  start_proxy
}
