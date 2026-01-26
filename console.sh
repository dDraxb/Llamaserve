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

# Load config.env if present (overrides above)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

LLAMA_SERVER_MODEL_FILE="${LLAMA_SERVER_MODEL_FILE:-$RUNTIME_DIR/llama_server.model}"

PYTHON_BIN="$LLAMA_SERVER_VENV/bin/python"
HFACE_CLI="$LLAMA_SERVER_VENV/bin/huggingface-cli"
LOG_FILE="$LLAMA_SERVER_LOG_DIR/llama_server.log"

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
}

restart_server() {
  stop_server
  start_server "${1:-}"
}

usage() {
  cat <<EOF
Usage: $0 <command> [model]

Commands:
  start [model]    Start server (optional model name/path)
  restart [model]  Restart server (optional model name/path)
  stop             Stop server
  status           Show server status
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
