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
LLAMA_SERVER_CHAT_FORMAT="${LLAMA_SERVER_CHAT_FORMAT:-}"
LLAMA_SERVER_HF_PRETRAINED_MODEL_NAME_OR_PATH="${LLAMA_SERVER_HF_PRETRAINED_MODEL_NAME_OR_PATH:-}"
LLAMA_SERVER_HF_TOKENIZER_CONFIG_PATH="${LLAMA_SERVER_HF_TOKENIZER_CONFIG_PATH:-}"
LLAMA_SERVER_HF_MODEL_REPO_ID="${LLAMA_SERVER_HF_MODEL_REPO_ID:-}"
LLAMA_SERVER_API_KEY="${LLAMA_SERVER_API_KEY:-}"
LLAMA_SERVER_PID_FILE="${LLAMA_SERVER_PID_FILE:-$RUNTIME_DIR/llama_server.pid}"
LLAMA_SERVER_MODEL_FILE="${LLAMA_SERVER_MODEL_FILE:-$RUNTIME_DIR/llama_server.model}"
LLAMA_SERVER_HOST_FILE="${LLAMA_SERVER_HOST_FILE:-$RUNTIME_DIR/llama_server.host}"
LLAMA_SERVER_PORT_FILE="${LLAMA_SERVER_PORT_FILE:-$RUNTIME_DIR/llama_server.port}"
LLAMA_SERVER_CUDA_VISIBLE_DEVICES="${LLAMA_SERVER_CUDA_VISIBLE_DEVICES:-}"
LLAMA_SERVER_DISABLE_METAL="${LLAMA_SERVER_DISABLE_METAL:-0}"
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
LIB_DIR="$ROOT_DIR/bin/lib"

if [[ -f "$LIB_DIR/common.sh" ]]; then
  # shellcheck disable=SC1090
  source "$LIB_DIR/common.sh"
fi
if [[ -f "$LIB_DIR/proxy.sh" ]]; then
  # shellcheck disable=SC1090
  source "$LIB_DIR/proxy.sh"
fi
if [[ -f "$LIB_DIR/server.sh" ]]; then
  # shellcheck disable=SC1090
  source "$LIB_DIR/server.sh"
fi

###############################################################################
# Helpers
###############################################################################

is_server_running() {
  local strict="${1:-0}"
  local effective_port="$LLAMA_SERVER_PORT"
  if [[ -f "$LLAMA_SERVER_PORT_FILE" ]]; then
    effective_port="$(cat "$LLAMA_SERVER_PORT_FILE" 2>/dev/null || echo "$LLAMA_SERVER_PORT")"
  fi
  if [[ -f "$LLAMA_SERVER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$LLAMA_SERVER_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && is_llama_process "$pid" && is_pid_listening_on_port "$pid" "$effective_port"; then
      return 0
    else
      rm -f "$LLAMA_SERVER_PID_FILE"
      if [[ "$strict" -eq 0 ]]; then
        local detected_pid
        detected_pid="$(find_pid_by_port "$effective_port")"
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
      detected_pid="$(find_pid_by_port "$effective_port")"
      if [[ -n "$detected_pid" ]] && is_llama_process "$detected_pid"; then
        echo "$detected_pid" > "$LLAMA_SERVER_PID_FILE"
        return 0
      fi
    fi
    return 1
  fi
}


has_running_instances() {
  if [[ -f "$LLAMA_MULTI_CONFIG" ]]; then
    local entry
    while IFS='|' read -r name _model _model_alias _host port _rest; do
      local effective_port="${port:-$LLAMA_SERVER_PORT}"
      if is_instance_running "$name" "$effective_port"; then
        return 0
      fi
    done < <(parse_multi_config)
    return 1
  fi

  if [[ ! -d "$INSTANCES_DIR" ]]; then
    return 1
  fi
  local pid_file
  for pid_file in "$INSTANCES_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && is_llama_process "$pid"; then
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
    local effective_host="$LLAMA_SERVER_HOST"
    local effective_port="$LLAMA_SERVER_PORT"
    if [[ -f "$LLAMA_SERVER_HOST_FILE" ]]; then
      effective_host="$(cat "$LLAMA_SERVER_HOST_FILE" 2>/dev/null || echo "$LLAMA_SERVER_HOST")"
    fi
    if [[ -f "$LLAMA_SERVER_PORT_FILE" ]]; then
      effective_port="$(cat "$LLAMA_SERVER_PORT_FILE" 2>/dev/null || echo "$LLAMA_SERVER_PORT")"
    fi
    echo "Server status: RUNNING"
    echo "  PID   : $pid"
    echo "  Bind  : $effective_host"
    echo "  Port  : $effective_port"
    echo "  URL   : $(client_url_for_bind "$effective_host" "$effective_port")"
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

  if [[ "$(uname -s)" == "Darwin" ]] && [[ "${LLAMA_ALLOW_UNPINNED:-0}" != "1" ]]; then
    local runtime_info
    runtime_info="$("$PYTHON_BIN" - <<'PY'
import sys
import llama_cpp
print(f"{sys.version_info.major}.{sys.version_info.minor}|{llama_cpp.__version__}")
PY
)"
    local py_mm="${runtime_info%%|*}"
    local llama_ver="${runtime_info##*|}"
    if [[ "$py_mm" != "3.11" && "$py_mm" != "3.12" ]]; then
      err "Unsupported Python on macOS: $py_mm (expected 3.11 or 3.12)."
      err "Rebuild runtime venv with Python 3.12 and rerun install."
      exit 1
    fi
    if [[ "$llama_ver" != "0.2.90" ]]; then
      err "Unsupported llama-cpp-python on macOS: $llama_ver (expected 0.2.90)."
      err "Run: ./runtime/install.sh"
      err "Set LLAMA_ALLOW_UNPINNED=1 only if you intentionally want an unpinned build."
      exit 1
    fi
  fi
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
  local model_arg=""
  local chat_format_arg=""
  local use_chat_template=0
  local disable_metal_arg=""
  local no_prompt=0
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --chat-format)
        shift || true
        chat_format_arg="${1:-}"
        ;;
      --use-chat-template)
        use_chat_template=1
        ;;
      --disable-metal)
        disable_metal_arg="1"
        ;;
      --no-prompt)
        no_prompt=1
        ;;
      *)
        if [[ -z "$model_arg" ]]; then
          model_arg="$arg"
        fi
        ;;
    esac
    shift || true
  done

  local -a catalog_entries=()
  if [[ -f "$LLAMA_MULTI_CONFIG" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && catalog_entries+=("$line")
    done < <(parse_multi_config)
  fi

  local selected_entry=""
  if [[ -n "$model_arg" ]] && [[ "${#catalog_entries[@]}" -gt 0 ]]; then
    local entry
    for entry in "${catalog_entries[@]}"; do
      IFS='|' read -r name model model_alias host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"$entry"
      if [[ "$model_arg" == "$name" ]] || [[ "$model_arg" == "$model" ]] || [[ "$model_arg" == "$(basename "$model")" ]]; then
        selected_entry="$entry"
        break
      fi
    done
  fi

  if [[ -z "$model_arg" ]] && [[ "${#catalog_entries[@]}" -gt 0 ]]; then
    if [[ "$no_prompt" -eq 1 ]]; then
      selected_entry="${catalog_entries[0]}"
    else
      echo "Available models:"
      local i
      for i in "${!catalog_entries[@]}"; do
        IFS='|' read -r name model model_alias host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"${catalog_entries[$i]}"
        printf "  [%d] %s (%s)\n" "$((i + 1))" "$name" "$(basename "$model")"
      done
      local choice
      while true; do
        read -r -p "Select a model [1-${#catalog_entries[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#catalog_entries[@]})); then
          selected_entry="${catalog_entries[$((choice - 1))]}"
          break
        fi
        err "Invalid selection."
      done
    fi
  fi

  if [[ -z "$model_arg" ]] && [[ "${#catalog_entries[@]}" -gt 0 ]] && [[ -z "$selected_entry" ]]; then
    err "No model selected."
    exit 1
  fi

  if [[ -z "$model_arg" ]] && [[ "${#catalog_entries[@]}" -eq 0 ]] && [[ "$no_prompt" -eq 1 ]]; then
    err "No models in catalog and prompts disabled."
    exit 1
  fi

  if [[ -z "$model_arg" ]] && [[ "${#catalog_entries[@]}" -eq 0 ]]; then
    model_path="$(select_model_interactively)"
  elif [[ -n "$selected_entry" ]]; then
    IFS='|' read -r name model model_alias host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"$selected_entry"
    model_path="$(resolve_model_path "$model")"
  else
    model_path="$(resolve_model_path "$model_arg")"
  fi

  if [[ -z "$model_path" ]]; then
    err "Unable to resolve model path."
    exit 1
  fi

  local effective_host="$LLAMA_SERVER_HOST"
  local effective_port="$LLAMA_SERVER_PORT"
  local effective_n_ctx="$LLAMA_SERVER_DEFAULT_N_CTX"
  local effective_n_gpu_layers="$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS"
  local effective_api_key="$LLAMA_SERVER_API_KEY"
  local effective_chat_format="$chat_format_arg"
  local effective_no_mmap=""
  local effective_flash_attn=""
  local effective_gpus="$LLAMA_SERVER_CUDA_VISIBLE_DEVICES"
  local effective_disable_metal="$disable_metal_arg"
  local effective_hf_pretrained_model_name_or_path="$LLAMA_SERVER_HF_PRETRAINED_MODEL_NAME_OR_PATH"
  local effective_hf_tokenizer_config_path="$LLAMA_SERVER_HF_TOKENIZER_CONFIG_PATH"
  local effective_hf_model_repo_id="$LLAMA_SERVER_HF_MODEL_REPO_ID"
  local raw_hf_tokenizer_config_path="$LLAMA_SERVER_HF_TOKENIZER_CONFIG_PATH"
  local effective_model_alias=""

  if [[ -n "$selected_entry" ]]; then
    IFS='|' read -r name model model_alias host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"$selected_entry"
    model_path="$(resolve_model_path "$model")"
    [[ -n "$model_alias" ]] && effective_model_alias="$model_alias"
    [[ -n "$host" ]] && effective_host="$host"
    [[ -n "$port" ]] && effective_port="$port"
    [[ -n "$n_ctx" ]] && effective_n_ctx="$n_ctx"
    [[ -n "$n_gpu_layers" ]] && effective_n_gpu_layers="$n_gpu_layers"
    [[ -n "$api_key" ]] && effective_api_key="$api_key"
    [[ -n "$chat_format" ]] && [[ -z "$effective_chat_format" ]] && effective_chat_format="$chat_format"
    [[ -n "$no_mmap" ]] && effective_no_mmap="$no_mmap"
    [[ -n "$flash_attn" ]] && effective_flash_attn="$flash_attn"
    [[ -n "$gpus" ]] && effective_gpus="$gpus"
    [[ -n "$disable_metal" ]] && [[ -z "$effective_disable_metal" ]] && effective_disable_metal="$disable_metal"
    [[ -n "$hf_pretrained_model_name_or_path" ]] && effective_hf_pretrained_model_name_or_path="$hf_pretrained_model_name_or_path"
    [[ -n "$hf_tokenizer_config_path" ]] && effective_hf_tokenizer_config_path="$hf_tokenizer_config_path"
    [[ -n "$hf_tokenizer_config_path" ]] && raw_hf_tokenizer_config_path="$hf_tokenizer_config_path"
    [[ -n "$hf_model_repo_id" ]] && effective_hf_model_repo_id="$hf_model_repo_id"
  else
    model_path="$(resolve_model_path "$model_arg")"
  fi

  effective_hf_tokenizer_config_path="$(resolve_support_file_path "$effective_hf_tokenizer_config_path")"
  validate_chat_handler_requirements \
    "single" \
    "$effective_chat_format" \
    "$effective_hf_pretrained_model_name_or_path" \
    "$raw_hf_tokenizer_config_path" \
    "$effective_hf_tokenizer_config_path"

  if is_truthy "$effective_disable_metal" && [[ "$effective_n_gpu_layers" == "-1" ]]; then
    # Disable full GPU offload when Metal is disabled on macOS.
    effective_n_gpu_layers="0"
  fi

  check_metal_backend_health "$model_path" "$effective_disable_metal"
  warn_large_model "$model_path" "$effective_n_gpu_layers" "$effective_gpus"

  local -a chat_format_args=()
  if [[ "$use_chat_template" -eq 1 ]] && [[ -z "$effective_chat_format" ]]; then
    effective_chat_format="chat_template.default"
  fi
  if [[ -n "$effective_chat_format" ]]; then
    chat_format_args=(--chat_format "$effective_chat_format")
  fi
  if [[ -n "$effective_no_mmap" ]]; then
    chat_format_args+=(--use_mmap false)
  fi
  if [[ -n "$effective_flash_attn" ]]; then
    chat_format_args+=(--flash_attn true)
  fi
  if [[ -n "$effective_hf_pretrained_model_name_or_path" ]]; then
    chat_format_args+=(--hf_pretrained_model_name_or_path "$effective_hf_pretrained_model_name_or_path")
  fi
  if [[ -n "$effective_hf_tokenizer_config_path" ]]; then
    chat_format_args+=(--hf_tokenizer_config_path "$effective_hf_tokenizer_config_path")
  fi
  if [[ -n "$effective_hf_model_repo_id" ]]; then
    chat_format_args+=(--hf_model_repo_id "$effective_hf_model_repo_id")
  fi
  if [[ -n "$effective_model_alias" ]]; then
    chat_format_args+=(--model_alias "$effective_model_alias")
  fi

  if [[ -n "$effective_gpus" ]]; then
    export CUDA_VISIBLE_DEVICES="$effective_gpus"
  fi

  LLAMA_SERVER_HOST="$effective_host"
  LLAMA_SERVER_PORT="$effective_port"
  LLAMA_SERVER_BACKEND_URL="http://$LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT"
  LLAMA_SERVER_DEFAULT_N_CTX="$effective_n_ctx"
  LLAMA_SERVER_DEFAULT_N_GPU_LAYERS="$effective_n_gpu_layers"
  LLAMA_SERVER_API_KEY="$effective_api_key"

  info "Starting llama_cpp.server..."
  info "Model: $model_path"
  info "Bind : $LLAMA_SERVER_HOST"
  info "Port : $LLAMA_SERVER_PORT"
  info "Log  : $LOG_FILE"

  local -a server_cmd=(
    "$PYTHON_BIN" -m llama_cpp.server
    --model "$model_path"
    --host "$LLAMA_SERVER_HOST"
    --port "$LLAMA_SERVER_PORT"
    --n_ctx "$LLAMA_SERVER_DEFAULT_N_CTX"
    --n_gpu_layers "$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS"
    --api_key "$LLAMA_SERVER_API_KEY"
  )
  if [[ "${#chat_format_args[@]}" -gt 0 ]]; then
    server_cmd+=("${chat_format_args[@]}")
  fi
  local -a clean_cmd=()
  local cmd_arg
  for cmd_arg in "${server_cmd[@]}"; do
    [[ -n "$cmd_arg" ]] && clean_cmd+=("$cmd_arg")
  done
  {
    printf "CMD:"
    for cmd_arg in "${clean_cmd[@]}"; do
      printf " %q" "$cmd_arg"
    done
    printf "\n"
  } >>"$LOG_FILE"
  if is_truthy "$effective_disable_metal"; then
    GGML_METAL=0 LLAMA_METAL=0 "${clean_cmd[@]}" >>"$LOG_FILE" 2>&1 &
  else
    "${clean_cmd[@]}" >>"$LOG_FILE" 2>&1 &
  fi
  echo $! > "$LLAMA_SERVER_PID_FILE"
  echo "$model_path" > "$LLAMA_SERVER_MODEL_FILE"
  echo "$LLAMA_SERVER_HOST" > "$LLAMA_SERVER_HOST_FILE"
  echo "$LLAMA_SERVER_PORT" > "$LLAMA_SERVER_PORT_FILE"

  local started_pid
  started_pid="$(cat "$LLAMA_SERVER_PID_FILE")"
  info "Server started with PID $started_pid"

  local attempts=0
  while [[ "$attempts" -lt 12 ]]; do
    if ! kill -0 "$started_pid" 2>/dev/null; then
      break
    fi
    if is_pid_listening_on_port "$started_pid" "$LLAMA_SERVER_PORT"; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.25
  done
  if ! kill -0 "$started_pid" 2>/dev/null; then
    err "Server exited early. Check log: $LOG_FILE"
    tail -n 20 "$LOG_FILE" >&2 || true
    rm -f "$LLAMA_SERVER_PID_FILE"
    return 1
  fi
  if ! is_pid_listening_on_port "$started_pid" "$LLAMA_SERVER_PORT"; then
    info "Server is still loading the model; not yet listening on port $LLAMA_SERVER_PORT. Check log: $LOG_FILE"
  fi

  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]]; then
    start_proxy
  fi
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

restart_server() {
  if [[ "$LLAMA_PROXY_ENABLED" == "1" ]]; then
    stop_proxy
  fi
  stop_server
  start_server "$@"
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  preflight            Run environment checks before install/start
  start single [model] [--chat-format fmt] [--use-chat-template] [--disable-metal] [--no-prompt] Start single server (optional model name/path)
  start multi [--no-prompt] Start multiple servers from $LLAMA_MULTI_CONFIG
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
    preflight)
      if [[ -x "$ROOT_DIR/bin/preflight.sh" ]]; then
        "$ROOT_DIR/bin/preflight.sh"
      else
        err "Missing preflight script: $ROOT_DIR/bin/preflight.sh"
        exit 1
      fi
      ;;
    start)
      assert_supported_shell
      local mode="${1:-}"
      shift || true
      case "$mode" in
        single)
          stop_multi
          start_server "$@"
          ;;
        multi)
          stop_server
          start_multi "$@"
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
      assert_supported_shell
      if is_server_running; then
        restart_server "$@"
      else
        stop_multi
        start_multi "$@"
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
          if has_running_instances; then
            status_multi "$strict"
          elif is_server_running "$strict"; then
            print_status "$strict"
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
      assert_supported_shell
      start_multi
      ;;
    stop-multi)
      stop_multi
      ;;
    status-multi)
      status_multi
      ;;
    start-proxy)
      assert_supported_shell
      start_proxy
      ;;
    restart-proxy)
      assert_supported_shell
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
