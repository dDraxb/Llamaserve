#!/usr/bin/env bash
# console.sh (place this in the project root folder)
set -euo pipefail

###############################################################################
# console.sh
#
# Master console for the local llama server.
#
# Project layout (relative to this script):
#   ./console.sh          - this file
#   ./runtime/            - venv, logs, config, install script
#   ./models/             - GGUF models
#
# Commands:
#   start    - if no server running: prompt for model in models/ and start it
#              if server running: refuse and tell you to use "restart"
#   restart  - stop existing server (if any), then prompt + start
#   stop     - stop server if running
#   status   - show whether server is running + basic info
###############################################################################

# Resolve project root based on where this script lives
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$SCRIPT_DIR"
RUNTIME_DIR="$ROOT_DIR/runtime"
MODELS_DIR="$ROOT_DIR/models"
CONFIG_FILE="$RUNTIME_DIR/config.env"

# Ensure runtime dir exists
mkdir -p "$RUNTIME_DIR" "$MODELS_DIR"

# Default values (can be overridden by config.env)
LLAMA_SERVER_ROOT="${LLAMA_SERVER_ROOT:-$ROOT_DIR}"
LLAMA_SERVER_RUNTIME_DIR="${LLAMA_SERVER_RUNTIME_DIR:-$RUNTIME_DIR}"
LLAMA_SERVER_VENV="${LLAMA_SERVER_VENV:-$RUNTIME_DIR/.venv}"
LLAMA_SERVER_MODELS_DIR="${LLAMA_SERVER_MODELS_DIR:-$MODELS_DIR}"
LLAMA_SERVER_LOG_DIR="${LLAMA_SERVER_LOG_DIR:-$RUNTIME_DIR/logs}"
LLAMA_SERVER_HOST="${LLAMA_SERVER_HOST:-0.0.0.0}"
LLAMA_SERVER_PORT="${LLAMA_SERVER_PORT:-8000}"
LLAMA_SERVER_DEFAULT_N_CTX="${LLAMA_SERVER_DEFAULT_N_CTX:-8192}"
LLAMA_SERVER_DEFAULT_N_GPU_LAYERS="${LLAMA_SERVER_DEFAULT_N_GPU_LAYERS:--1}"
LLAMA_SERVER_API_KEY="${LLAMA_SERVER_API_KEY:-}"
LLAMA_SERVER_PID_FILE="${LLAMA_SERVER_PID_FILE:-$RUNTIME_DIR/llama_server.pid}"
LLAMA_SERVER_MODEL_FILE="${LLAMA_SERVER_MODEL_FILE:-$RUNTIME_DIR/llama_server.model}"
LLAMA_SERVER_CUDA_VISIBLE_DEVICES="${LLAMA_SERVER_CUDA_VISIBLE_DEVICES:-}"
LLAMA_PROXY_ENABLED="${LLAMA_PROXY_ENABLED:-0}"
LLAMA_PROXY_HOST="${LLAMA_PROXY_HOST:-0.0.0.0}"
LLAMA_PROXY_PORT="${LLAMA_PROXY_PORT:-8001}"
LLAMA_PROXY_PID_FILE="${LLAMA_PROXY_PID_FILE:-$RUNTIME_DIR/llama_proxy.pid}"

# Load config.env if present (overrides above)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

LLAMA_SERVER_MODEL_FILE="${LLAMA_SERVER_MODEL_FILE:-$RUNTIME_DIR/llama_server.model}"

PYTHON_BIN="$LLAMA_SERVER_VENV/bin/python"
HFACE_CLI="$LLAMA_SERVER_VENV/bin/huggingface-cli"
LOG_FILE="$LLAMA_SERVER_LOG_DIR/llama_server.log"
PROXY_LOG_FILE="$LLAMA_SERVER_LOG_DIR/llama_proxy.log"
LLAMA_SERVER_BACKEND_URL="${LLAMA_SERVER_BACKEND_URL:-http://127.0.0.1:$LLAMA_SERVER_PORT}"

###############################################################################
# Helpers
###############################################################################

err() {
  echo "ERROR: $*" >&2
}

info() {
  echo ">>> $*"
}

is_server_running() {
  if [[ -f "$LLAMA_SERVER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$LLAMA_SERVER_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    else
      rm -f "$LLAMA_SERVER_PID_FILE"
      return 1
    fi
  else
    return 1
  fi
}

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

print_status() {
  if is_server_running; then
    local pid
    pid="$(cat "$LLAMA_SERVER_PID_FILE")"
    local model="(unknown)"
    if [[ -f "$LLAMA_SERVER_MODEL_FILE" ]]; then
      model="$(cat "$LLAMA_SERVER_MODEL_FILE")"
    fi
    echo "Server status: RUNNING"
    echo "  PID   : $pid"
    echo "  Host  : $LLAMA_SERVER_HOST"
    echo "  Port  : $LLAMA_SERVER_PORT"
    echo "  URL   : http://$LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT/v1"
    echo "  Model : $model"
    echo "  Log   : $LOG_FILE"
  else
    echo "Server status: NOT RUNNING"
    if [[ -f "$LLAMA_SERVER_MODEL_FILE" ]]; then
      local last_model
      last_model="$(cat "$LLAMA_SERVER_MODEL_FILE")"
      echo "  Last model: $last_model"
    fi
  fi

  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]] || is_proxy_running; then
    if is_proxy_running; then
      local ppid
      ppid="$(cat "$LLAMA_PROXY_PID_FILE")"
      echo "Proxy status : RUNNING"
      echo "  PID   : $ppid"
      echo "  Host  : $LLAMA_PROXY_HOST"
      echo "  Port  : $LLAMA_PROXY_PORT"
      echo "  URL   : http://$LLAMA_PROXY_HOST:$LLAMA_PROXY_PORT/v1"
      echo "  Log   : $PROXY_LOG_FILE"
    else
      echo "Proxy status : NOT RUNNING"
    fi
  fi
}

ensure_venv_and_deps() {
  if [[ ! -x "$PYTHON_BIN" ]]; then
    err "Virtualenv not found at $LLAMA_SERVER_VENV"
    err "Run the install script first: $RUNTIME_DIR/install.sh"
    exit 1
  fi

  "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1 || {
import importlib
for m in ("llama_cpp",):
    importlib.import_module(m)
PY
  if [[ $? -ne 0 ]]; then
    err "llama_cpp not importable in venv. Re-run: $RUNTIME_DIR/install.sh"
    exit 1
  fi
  }
}

ensure_proxy_deps() {
  "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1 || {
import importlib
for m in ("fastapi", "uvicorn", "httpx", "psycopg2"):
    importlib.import_module(m)
PY
  if [[ $? -ne 0 ]]; then
    err "Proxy deps missing in venv. Re-run: $RUNTIME_DIR/install.sh"
    exit 1
  fi
  }
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^# ]] && continue
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

ensure_db_url() {
  load_env_file "$ROOT_DIR/.env"
  if [[ -z "${POSTGRES_AUTH_USER:-}" ]] || [[ -z "${POSTGRES_AUTH_PASSWORD:-}" ]] || [[ -z "${POSTGRES_AUTH_DB:-}" ]]; then
    err "Database config not set. Provide POSTGRES_AUTH_USER/POSTGRES_AUTH_PASSWORD/POSTGRES_AUTH_DB in .env."
    exit 1
  fi
  local host="${POSTGRES_AUTH_HOST:-localhost}"
  local port="${POSTGRES_AUTH_PORT:-5432}"
  export LLAMA_SERVER_DATABASE_URL="postgresql://${POSTGRES_AUTH_USER}:${POSTGRES_AUTH_PASSWORD}@${host}:${port}/${POSTGRES_AUTH_DB}"
}

ensure_at_least_one_model() {
  if ls "$LLAMA_SERVER_MODELS_DIR"/*.gguf >/dev/null 2>&1; then
    return 0
  fi

  info "models/ directory is empty."
  info "Attempting to download fallback TinyLlama 1.1B Chat (Q4_K_M GGUF) ..."
  info "Source: TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF (Hugging Face)"
  echo

  if [[ -z "${HF_TOKEN:-}" ]] && [[ -t 0 ]]; then
    read -r -p "Optional: enter HF_TOKEN for higher rate limits (leave blank to skip): " HF_TOKEN_INPUT
    if [[ -n "$HF_TOKEN_INPUT" ]]; then
      export HF_TOKEN="$HF_TOKEN_INPUT"
    fi
  fi

  if [[ -x "$HFACE_CLI" ]]; then
    "$HFACE_CLI" download \
      TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
      tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
      --local-dir "$LLAMA_SERVER_MODELS_DIR" \
      --local-dir-use-symlinks False
  else
    "$PYTHON_BIN" - <<PY
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id="TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    filename="tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    local_dir=r"""$LLAMA_SERVER_MODELS_DIR""",
    local_dir_use_symlinks=False,
)
PY
  fi

  info "Fallback model downloaded into: $LLAMA_SERVER_MODELS_DIR"
}

select_model_interactively() {
  local -a models
  local model_count
  mapfile -t models < <(find "$LLAMA_SERVER_MODELS_DIR" -maxdepth 1 -type f -name "*.gguf" | sort)
  model_count="${#models[@]}"

  if [[ "$model_count" -eq 0 ]]; then
    err "No GGUF models found in $LLAMA_SERVER_MODELS_DIR"
    exit 1
  fi

  if [[ "$model_count" -eq 1 ]]; then
    local only_model
    only_model="${models[0]}"
    echo "Using only available model: $(basename "$only_model")" >&2
    echo "$only_model"
    return 0
  fi

  echo "Available models:"
  local i
  for i in "${!models[@]}"; do
    printf "  [%d] %s\n" "$((i + 1))" "$(basename "${models[$i]}")"
  done

  local choice
  while true; do
    read -r -p "Select a model [1-$model_count]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= model_count)); then
      echo "${models[$((choice - 1))]}"
      return 0
    fi
    err "Invalid selection."
  done
}

resolve_model_path() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    select_model_interactively
    return 0
  fi

  if [[ -f "$input" ]]; then
    echo "$input"
    return 0
  fi

  if [[ -f "$LLAMA_SERVER_MODELS_DIR/$input" ]]; then
    echo "$LLAMA_SERVER_MODELS_DIR/$input"
    return 0
  fi

  err "Model not found: $input"
  exit 1
}

ensure_api_key() {
  if [[ -z "$LLAMA_SERVER_API_KEY" ]]; then
    err "LLAMA_SERVER_API_KEY is not set. Run: $RUNTIME_DIR/install.sh"
    exit 1
  fi
}

start_server() {
  if is_server_running; then
    err "Server already running. Use: $0 restart"
    exit 1
  fi

  ensure_venv_and_deps
  ensure_at_least_one_model
  ensure_api_key
  mkdir -p "$LLAMA_SERVER_LOG_DIR"

  local model_path
  model_path="$(resolve_model_path "${1:-}")"

  if [[ -n "$LLAMA_SERVER_CUDA_VISIBLE_DEVICES" ]]; then
    export CUDA_VISIBLE_DEVICES="$LLAMA_SERVER_CUDA_VISIBLE_DEVICES"
  fi

  info "Starting llama_cpp.server..."
  info "Model: $model_path"
  info "Host : $LLAMA_SERVER_HOST"
  info "Port : $LLAMA_SERVER_PORT"
  info "Log  : $LOG_FILE"

  "$PYTHON_BIN" -m llama_cpp.server \
    --model "$model_path" \
    --host "$LLAMA_SERVER_HOST" \
    --port "$LLAMA_SERVER_PORT" \
    --n_ctx "$LLAMA_SERVER_DEFAULT_N_CTX" \
    --n_gpu_layers "$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS" \
    --api_key "$LLAMA_SERVER_API_KEY" >>"$LOG_FILE" 2>&1 &
  echo $! > "$LLAMA_SERVER_PID_FILE"
  echo "$model_path" > "$LLAMA_SERVER_MODEL_FILE"

  local started_pid
  started_pid="$(cat "$LLAMA_SERVER_PID_FILE")"
  info "Server started with PID $started_pid"

  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]]; then
    start_proxy
  fi
}

start_proxy() {
  if is_proxy_running; then
    err "Proxy already running. Use: $0 restart-proxy"
    exit 1
  fi

  ensure_venv_and_deps
  ensure_proxy_deps
  ensure_db_url
  mkdir -p "$LLAMA_SERVER_LOG_DIR"

  export LLAMA_SERVER_BACKEND_URL="${LLAMA_SERVER_BACKEND_URL:-http://127.0.0.1:$LLAMA_SERVER_PORT}"

  info "Starting auth proxy..."
  info "Backend: $LLAMA_SERVER_BACKEND_URL"
  info "Host   : $LLAMA_PROXY_HOST"
  info "Port   : $LLAMA_PROXY_PORT"
  info "Log    : $PROXY_LOG_FILE"

  "$PYTHON_BIN" -m uvicorn auth_proxy:app \
    --app-dir "$RUNTIME_DIR" \
    --host "$LLAMA_PROXY_HOST" \
    --port "$LLAMA_PROXY_PORT" >>"$PROXY_LOG_FILE" 2>&1 &

  echo $! > "$LLAMA_PROXY_PID_FILE"
  info "Proxy started with PID $(cat "$LLAMA_PROXY_PID_FILE")"
}

stop_server() {
  if ! is_server_running; then
    info "Server is not running."
    return 0
  fi

  local pid
  pid="$(cat "$LLAMA_SERVER_PID_FILE")"
  info "Stopping server (PID $pid)..."
  kill "$pid" 2>/dev/null || true

  local i
  for i in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$LLAMA_SERVER_PID_FILE"
      info "Server stopped."
      return 0
    fi
    sleep 0.25
  done

  err "Server did not stop gracefully; sending SIGKILL."
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$LLAMA_SERVER_PID_FILE"
  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]]; then
    stop_proxy
  fi
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

restart_server() {
  stop_server
  start_server "${1:-}"
}

restart_proxy() {
  stop_proxy
  start_proxy
}

usage() {
  cat <<EOF
Usage: $0 <command> [model]

Commands:
  start [model]    Start server (optional model name/path)
  restart [model]  Restart server (optional model name/path)
  stop             Stop server
  status           Show server status
  start-proxy      Start auth proxy
  restart-proxy    Restart auth proxy
  stop-proxy       Stop auth proxy
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start)
      start_server "${1:-}"
      ;;
    restart)
      restart_server "${1:-}"
      ;;
    stop)
      stop_server
      ;;
    status)
      print_status
      ;;
    start-proxy)
      start_proxy
      ;;
    restart-proxy)
      restart_proxy
      ;;
    stop-proxy)
      stop_proxy
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      err "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
