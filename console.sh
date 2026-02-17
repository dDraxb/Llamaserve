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
LLAMA_SERVER_LOG_DIR="${LLAMA_SERVER_LOG_DIR:-$ROOT_DIR/logs}"
LLAMA_SERVER_HOST="${LLAMA_SERVER_HOST:-127.0.0.1}"
LLAMA_SERVER_PORT="${LLAMA_SERVER_PORT:-8002}"
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
LLAMA_MULTI_CONFIG="${LLAMA_MULTI_CONFIG:-$ROOT_DIR/config/models.yaml}"

# Load config.env if present (overrides above)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

LLAMA_SERVER_MODEL_FILE="${LLAMA_SERVER_MODEL_FILE:-$RUNTIME_DIR/llama_server.model}"

VENV_BIN_DIR="$LLAMA_SERVER_VENV/bin"
if [[ ! -d "$VENV_BIN_DIR" ]]; then
  VENV_BIN_DIR="$LLAMA_SERVER_VENV/Scripts"
fi

PYTHON_BIN="$VENV_BIN_DIR/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="$VENV_BIN_DIR/python.exe"
fi

HFACE_CLI="$VENV_BIN_DIR/huggingface-cli"
if [[ ! -x "$HFACE_CLI" ]]; then
  HFACE_CLI="$VENV_BIN_DIR/huggingface-cli.exe"
fi
LOG_FILE="$LLAMA_SERVER_LOG_DIR/llama_server.log"
PROXY_LOG_FILE="$LLAMA_SERVER_LOG_DIR/llama_proxy.log"
LLAMA_SERVER_BACKEND_URL="${LLAMA_SERVER_BACKEND_URL:-http://127.0.0.1:$LLAMA_SERVER_PORT}"
INSTANCES_DIR="$RUNTIME_DIR/instances"

###############################################################################
# Helpers
###############################################################################

err() {
  echo "ERROR: $*" >&2
}

info() {
  echo ">>> $*"
}

warn_large_model() {
  local model_path="$1"
  local n_gpu_layers="$2"
  local gpus="$3"
  if [[ -f "$model_path" ]]; then
    local size_bytes
    size_bytes="$(stat -f%z "$model_path" 2>/dev/null || stat -c%s "$model_path" 2>/dev/null || echo 0)"
    if [[ "$size_bytes" -gt 12000000000 ]]; then
      if [[ -z "$gpus" ]] || [[ "$n_gpu_layers" == "-1" ]]; then
        echo "WARNING: Large model detected (~$((size_bytes / 1024 / 1024 / 1024))GB). Ensure you have enough VRAM/RAM and GPU layers set appropriately." >&2
      fi
    fi
  fi
}
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

client_host_for_bind() {
  local host="$1"
  if [[ "$host" == "0.0.0.0" ]]; then
    echo "127.0.0.1"
  else
    echo "$host"
  fi
}

client_url_for_bind() {
  local host="$1"
  local port="$2"
  local client_host
  client_host="$(client_host_for_bind "$host")"
  echo "http://$client_host:$port/v1"
}

is_server_running() {
  local strict="${1:-0}"
  if [[ -f "$LLAMA_SERVER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$LLAMA_SERVER_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    else
      rm -f "$LLAMA_SERVER_PID_FILE"
      if [[ "$strict" -eq 0 ]]; then
        local detected_pid
        detected_pid="$(find_pid_by_port "$LLAMA_SERVER_PORT")"
        if [[ -n "$detected_pid" ]] && is_llama_process "$detected_pid"; then
          echo "$detected_pid" > "$LLAMA_SERVER_PID_FILE"
          return 0
        fi
      fi
      return 1
    fi
  else
    if [[ "$strict" -eq 0 ]]; then
      local detected_pid
      detected_pid="$(find_pid_by_port "$LLAMA_SERVER_PORT")"
      if [[ -n "$detected_pid" ]] && is_llama_process "$detected_pid"; then
        echo "$detected_pid" > "$LLAMA_SERVER_PID_FILE"
        return 0
      fi
    fi
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

find_pid_by_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2; exit}'
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p' | head -n1
    return 0
  fi
  return 1
}

is_llama_process() {
  local pid="$1"
  if command -v ps >/dev/null 2>&1; then
    local cmd
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ -z "$cmd" ]]; then
      return 0
    fi
    echo "$cmd" | grep -q "llama_cpp.server"
    return $?
  fi
  return 0
}

has_running_instances() {
  if [[ ! -d "$INSTANCES_DIR" ]]; then
    return 1
  fi
  local pid_file
  for pid_file in "$INSTANCES_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

print_status() {
  local strict="${1:-0}"
  if is_server_running "$strict"; then
    echo "Mode : single"
    local pid
    pid="$(cat "$LLAMA_SERVER_PID_FILE")"
    local model="(unknown)"
    if [[ -f "$LLAMA_SERVER_MODEL_FILE" ]]; then
      model="$(cat "$LLAMA_SERVER_MODEL_FILE")"
    fi
    echo "Server status: RUNNING"
    echo "  PID   : $pid"
    echo "  Bind  : $LLAMA_SERVER_HOST"
    echo "  Port  : $LLAMA_SERVER_PORT"
    echo "  URL   : $(client_url_for_bind "$LLAMA_SERVER_HOST" "$LLAMA_SERVER_PORT")"
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
      echo "  Bind  : $LLAMA_PROXY_HOST"
      echo "  Port  : $LLAMA_PROXY_PORT"
      echo "  URL   : $(client_url_for_bind "$LLAMA_PROXY_HOST" "$LLAMA_PROXY_PORT")"
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
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" != *"="* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="$(trim "$key")"
    value="$(trim "$value")"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    if [[ -n "$key" ]] && [[ -z "${!key:-}" ]]; then
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
  if find "$LLAMA_SERVER_MODELS_DIR" -maxdepth 2 -type f -name "*.gguf" -print -quit >/dev/null 2>&1; then
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

instance_pid_file() {
  echo "$INSTANCES_DIR/$1.pid"
}

instance_model_file() {
  echo "$INSTANCES_DIR/$1.model"
}

instance_log_file() {
  echo "$LLAMA_SERVER_LOG_DIR/llama_server_$1.log"
}

is_instance_running() {
  local name="$1"
  local pid_file
  pid_file="$(instance_pid_file "$name")"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    else
      rm -f "$pid_file"
      return 1
    fi
  fi
  return 1
}

repair_instance_pid() {
  local name="$1"
  local port="$2"
  if [[ -z "$port" ]]; then
    return 1
  fi
  local detected_pid
  detected_pid="$(find_pid_by_port "$port")"
  if [[ -n "$detected_pid" ]] && is_llama_process "$detected_pid"; then
    echo "$detected_pid" > "$(instance_pid_file "$name")"
    return 0
  fi
  return 1
}

start_instance() {
  local name="$1"
  local model_input="$2"
  local host="$3"
  local port="$4"
  local gpus="$5"
  local n_ctx="$6"
  local n_gpu_layers="$7"
  local api_key="$8"

  mkdir -p "$INSTANCES_DIR" "$LLAMA_SERVER_LOG_DIR"

  if is_instance_running "$name"; then
    err "Instance already running: $name"
    return 1
  fi

  local model_path
  model_path="$(resolve_model_path "$model_input")"
  warn_large_model "$model_path" "$n_gpu_layers" "$gpus"

  local log_file
  log_file="$(instance_log_file "$name")"

  local effective_api_key="$api_key"
  if [[ -z "$effective_api_key" ]]; then
    effective_api_key="$LLAMA_SERVER_API_KEY"
  fi
  if [[ -z "$effective_api_key" ]]; then
    err "API key missing for instance: $name"
    return 1
  fi

  local effective_host="$host"
  local effective_port="$port"
  local effective_n_ctx="$n_ctx"
  local effective_n_gpu_layers="$n_gpu_layers"

  [[ -z "$effective_host" ]] && effective_host="$LLAMA_SERVER_HOST"
  [[ -z "$effective_port" ]] && effective_port="$LLAMA_SERVER_PORT"
  [[ -z "$effective_n_ctx" ]] && effective_n_ctx="$LLAMA_SERVER_DEFAULT_N_CTX"
  [[ -z "$effective_n_gpu_layers" ]] && effective_n_gpu_layers="$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS"

  info "Starting instance [$name]..."
  info "  Model: $model_path"
  info "  Bind : $effective_host"
  info "  Port : $effective_port"
  info "  Log  : $log_file"

  if [[ -n "$gpus" ]]; then
    CUDA_VISIBLE_DEVICES="$gpus" \
      "$PYTHON_BIN" -m llama_cpp.server \
        --model "$model_path" \
        --host "$effective_host" \
        --port "$effective_port" \
        --n_ctx "$effective_n_ctx" \
        --n_gpu_layers "$effective_n_gpu_layers" \
        --api_key "$effective_api_key" >>"$log_file" 2>&1 &
  else
    "$PYTHON_BIN" -m llama_cpp.server \
      --model "$model_path" \
      --host "$effective_host" \
      --port "$effective_port" \
      --n_ctx "$effective_n_ctx" \
      --n_gpu_layers "$effective_n_gpu_layers" \
      --api_key "$effective_api_key" >>"$log_file" 2>&1 &
  fi

  echo $! > "$(instance_pid_file "$name")"
  echo "$model_path" > "$(instance_model_file "$name")"
  info "Instance [$name] started with PID $(cat "$(instance_pid_file "$name")")"
}

stop_instance() {
  local name="$1"
  local pid_file
  pid_file="$(instance_pid_file "$name")"
  if [[ ! -f "$pid_file" ]]; then
    info "Instance not running: $name"
    return 0
  fi
  local pid
  pid="$(cat "$pid_file")"
  info "Stopping instance [$name] (PID $pid)..."
  kill "$pid" 2>/dev/null || true

  local i
  for i in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file"
      rm -f "$(instance_model_file "$name")"
      info "Instance [$name] stopped."
      return 0
    fi
    sleep 0.25
  done

  err "Instance [$name] did not stop gracefully; sending SIGKILL."
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  rm -f "$(instance_model_file "$name")"
}

parse_multi_config() {
  if [[ ! -f "$LLAMA_MULTI_CONFIG" ]]; then
    err "Multi config not found: $LLAMA_MULTI_CONFIG"
    exit 1
  fi
  "$PYTHON_BIN" - <<PY
import sys, yaml
from pathlib import Path

path = Path(r"""$LLAMA_MULTI_CONFIG""")
data = yaml.safe_load(path.read_text()) or {}
instances = data.get("instances", [])
for inst in instances:
    name = (inst.get("name") or "").strip()
    if not name:
        continue
    model = (inst.get("model") or "").strip()
    host = (inst.get("host") or "").strip()
    port = str(inst.get("port") or "").strip()
    gpus = (inst.get("cuda_visible_devices") or "").strip()
    n_ctx = str(inst.get("n_ctx") or "").strip()
    n_gpu_layers = str(inst.get("n_gpu_layers") or "").strip()
    api_key = (inst.get("api_key") or "").strip()
    print("|".join([name, model, host, port, gpus, n_ctx, n_gpu_layers, api_key]))
PY
}

start_multi() {
  ensure_venv_and_deps
  ensure_at_least_one_model
  mkdir -p "$INSTANCES_DIR" "$LLAMA_SERVER_LOG_DIR"

  local entry
  while IFS='|' read -r name model host port gpus n_ctx n_gpu_layers api_key; do
    if is_instance_running "$name"; then
      err "Instance already running, skipping: $name"
      continue
    fi
    start_instance "$name" "$model" "$host" "$port" "$gpus" "$n_ctx" "$n_gpu_layers" "$api_key"
  done < <(parse_multi_config)
}

stop_multi() {
  if [[ -f "$LLAMA_MULTI_CONFIG" ]]; then
    local entry
    while IFS='|' read -r name _; do
      stop_instance "$name"
    done < <(parse_multi_config)
    return 0
  fi

  if [[ -d "$INSTANCES_DIR" ]]; then
    local pid_file
    for pid_file in "$INSTANCES_DIR"/*.pid; do
      [[ -e "$pid_file" ]] || continue
      local name
      name="$(basename "$pid_file" .pid)"
      stop_instance "$name"
    done
  fi
}

status_multi() {
  local strict="${1:-0}"
  echo "Mode : multi"
  if [[ -f "$LLAMA_MULTI_CONFIG" ]]; then
    local entry
    while IFS='|' read -r name model host port gpus n_ctx n_gpu_layers api_key; do
      local effective_port="${port:-$LLAMA_SERVER_PORT}"
      if ! is_instance_running "$name" && [[ "$strict" -eq 0 ]]; then
        repair_instance_pid "$name" "$effective_port" || true
      fi
      if is_instance_running "$name"; then
        local pid
        pid="$(cat "$(instance_pid_file "$name")")"
        local model_path="(unknown)"
        if [[ -f "$(instance_model_file "$name")" ]]; then
          model_path="$(cat "$(instance_model_file "$name")")"
        fi
        local log_file
        log_file="$(instance_log_file "$name")"
        local effective_host="${host:-$LLAMA_SERVER_HOST}"
        echo "Instance [$name]: RUNNING"
        echo "  PID   : $pid"
        echo "  Bind  : $effective_host"
        echo "  Port  : $effective_port"
        echo "  URL   : $(client_url_for_bind "$effective_host" "$effective_port")"
        echo "  Model : $model_path"
        echo "  Log   : $log_file"
      else
        echo "Instance [$name]: NOT RUNNING"
      fi
    done < <(parse_multi_config)
    return 0
  fi

  local pid_file
  for pid_file in "$INSTANCES_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local name
    name="$(basename "$pid_file" .pid)"
    if is_instance_running "$name"; then
      local pid
      pid="$(cat "$pid_file")"
      local model_path="(unknown)"
      if [[ -f "$(instance_model_file "$name")" ]]; then
        model_path="$(cat "$(instance_model_file "$name")")"
      fi
      echo "Instance [$name]: RUNNING"
      echo "  PID   : $pid"
      echo "  Model : $model_path"
      echo "  Log   : $(instance_log_file "$name")"
    else
      echo "Instance [$name]: NOT RUNNING"
    fi
  done
}

select_shard_from_dir() {
  local dir="$1"
  local shard
  shard="$(find "$dir" -maxdepth 1 -type f -name "*-00001-of-*.gguf" | sort | head -n 1)"
  if [[ -n "$shard" ]]; then
    echo "$shard"
    return 0
  fi
  shard="$(find "$dir" -maxdepth 1 -type f -name "*.gguf" | sort | head -n 1)"
  if [[ -n "$shard" ]]; then
    echo "$shard"
    return 0
  fi
  return 1
}

select_shard_by_prefix() {
  local prefix="$1"
  local shard
  shard="$(find "$LLAMA_SERVER_MODELS_DIR" -maxdepth 1 -type f -name "${prefix}-00001-of-*.gguf" | sort | head -n 1)"
  if [[ -n "$shard" ]]; then
    echo "$shard"
    return 0
  fi
  return 1
}

select_model_interactively() {
  local -a models
  local -a targets
  local -a shard_prefixes
  local -a shard_paths
  local -a top_files
  local -a model_dirs
  local shard_in_root=0
  local model_count

  while IFS= read -r line; do
    top_files+=("$line")
  done < <(find "$LLAMA_SERVER_MODELS_DIR" -maxdepth 1 -type f -name "*.gguf" | sort)

  local file
  for file in "${top_files[@]}"; do
    local base
    base="$(basename "$file")"
    if [[ "$base" =~ ^(.*)-00001-of-[0-9]+\.gguf$ ]]; then
      shard_prefixes+=("${BASH_REMATCH[1]}")
      shard_paths+=("$file")
      shard_in_root=1
    fi
  done

  local dir
  while IFS= read -r dir; do
    if [[ "$dir" == "$LLAMA_SERVER_MODELS_DIR" ]]; then
      continue
    fi
    if find "$dir" -maxdepth 1 -type f -name "*.gguf" | rg -q "."; then
      local dir_name
      dir_name="$(basename "$dir")"
      local shard
      shard="$(select_shard_from_dir "$dir" || true)"
      if [[ -n "$shard" ]]; then
        models+=("${dir_name}/ (sharded)")
        targets+=("$shard")
      fi
    fi
  done < <(find "$LLAMA_SERVER_MODELS_DIR" -maxdepth 1 -type d | sort)

  local i
  for i in "${!shard_prefixes[@]}"; do
    models+=("${shard_prefixes[$i]} (sharded)")
    targets+=("${shard_paths[$i]}")
  done

  for file in "${top_files[@]}"; do
    local base
    base="$(basename "$file")"
    if [[ "$base" =~ ^(.*)-0000[0-9]-of-[0-9]+\.gguf$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local skip=0
      local p
      for p in "${shard_prefixes[@]}"; do
        if [[ "$p" == "$prefix" ]]; then
          skip=1
          break
        fi
      done
      if [[ "$skip" -eq 1 ]]; then
        continue
      fi
    fi
    models+=("$base")
    targets+=("$file")
  done

  model_count="${#models[@]}"

  if [[ "$model_count" -eq 0 ]]; then
    err "No GGUF models found in $LLAMA_SERVER_MODELS_DIR"
    exit 1
  fi

  if [[ "$shard_in_root" -eq 1 ]]; then
    echo "Warning: Sharded GGUF files found in $LLAMA_SERVER_MODELS_DIR." >&2
    echo "Consider moving each shard set into its own subfolder for cleaner selection." >&2
  fi

  if [[ "$model_count" -eq 1 ]]; then
    local only_model
    only_model="${models[0]}"
    echo "Using only available model: $only_model" >&2
    echo "${targets[0]}"
    return 0
  fi

  echo "Available models:" >&2
  for i in "${!models[@]}"; do
    printf "  [%d] %s\n" "$((i + 1))" "${models[$i]}" >&2
  done

  local choice
  while true; do
    read -r -p "Select a model [1-$model_count]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= model_count)); then
      echo "${targets[$((choice - 1))]}"
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

  if [[ -d "$input" ]]; then
    local shard
    shard="$(select_shard_from_dir "$input" || true)"
    if [[ -n "$shard" ]]; then
      echo "$shard"
      return 0
    fi
  fi

  if [[ -d "$LLAMA_SERVER_MODELS_DIR/$input" ]]; then
    local shard
    shard="$(select_shard_from_dir "$LLAMA_SERVER_MODELS_DIR/$input" || true)"
    if [[ -n "$shard" ]]; then
      echo "$shard"
      return 0
    fi
  fi

  if [[ -f "$LLAMA_SERVER_MODELS_DIR/$input" ]]; then
    echo "$LLAMA_SERVER_MODELS_DIR/$input"
    return 0
  fi

  local shard
  shard="$(select_shard_by_prefix "$input" || true)"
  if [[ -n "$shard" ]]; then
    echo "$shard"
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
  warn_large_model "$model_path" "$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS" "$LLAMA_SERVER_CUDA_VISIBLE_DEVICES"

  if [[ -n "$LLAMA_SERVER_CUDA_VISIBLE_DEVICES" ]]; then
    export CUDA_VISIBLE_DEVICES="$LLAMA_SERVER_CUDA_VISIBLE_DEVICES"
  fi

  info "Starting llama_cpp.server..."
  info "Model: $model_path"
  info "Bind : $LLAMA_SERVER_HOST"
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
  info "Bind   : $LLAMA_PROXY_HOST"
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
  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]]; then
    stop_proxy
  fi
  stop_server
  start_server "${1:-}"
}

restart_proxy() {
  stop_proxy
  start_proxy
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  start single [model] Start single server (optional model name/path)
  start multi          Start multiple servers from $LLAMA_MULTI_CONFIG
  restart [model]      Restart current mode (single or multi)
  stop                 Stop current mode (single or multi)
  status [single|multi] [--strict] Show what's running (single or multi)
  start-multi            Start multiple servers (legacy)
  stop-multi             Stop multiple servers (legacy)
  status-multi           Show status for multi servers (legacy)
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
      local mode="${1:-}"
      shift || true
      case "$mode" in
        single)
          stop_multi
          start_server "${1:-}"
          ;;
        multi)
          stop_server
          start_multi
          ;;
        ""|help|-h|--help)
          usage
          exit 1
          ;;
        *)
          err "Unknown start mode: $mode"
          usage
          exit 1
          ;;
      esac
      ;;
    restart)
      if is_server_running; then
        restart_server "${1:-}"
      else
        stop_multi
        start_multi
      fi
      ;;
    stop)
      stop_server
      stop_multi
      ;;
    status)
      local mode=""
      local strict=0
      local arg
      for arg in "$@"; do
        case "$arg" in
          --strict)
            strict=1
            ;;
          single|multi)
            mode="$arg"
            ;;
          *)
            err "Unknown status filter: $arg"
            usage
            exit 1
            ;;
        esac
      done
      case "$mode" in
        "")
          if is_server_running "$strict"; then
            print_status "$strict"
          elif has_running_instances; then
            status_multi "$strict"
          else
            echo "Mode : none"
            print_status "$strict"
          fi
          ;;
        single)
          print_status "$strict"
          ;;
        multi)
          if has_running_instances; then
            status_multi "$strict"
          else
            echo "Mode : none"
            echo "No multi instances running."
          fi
          ;;
      esac
      ;;
    start-multi)
      start_multi
      ;;
    stop-multi)
      stop_multi
      ;;
    status-multi)
      status_multi
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
