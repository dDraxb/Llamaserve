#!/usr/bin/env bash
# runtime/install.sh
set -euo pipefail

###############################################################################
# llama-server install script
# - Creates runtime + models directories
# - Creates venv and installs llama-cpp-python[server] + huggingface_hub
# - Generates config.env with absolute paths
# - If models/ is empty, downloads TinyLlama 1.1B Chat (Q4_K_M GGUF) as fallback
###############################################################################

# Resolve paths based on where this script lives
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SCRIPT_DIR"
MODELS_DIR="$ROOT_DIR/models"
VENV_DIR="$RUNTIME_DIR/.venv"
LOG_DIR="$RUNTIME_DIR/logs"
CONFIG_FILE="$RUNTIME_DIR/config.env"
ENV_FILE="$ROOT_DIR/.env"

mkdir -p "$RUNTIME_DIR" "$MODELS_DIR" "$LOG_DIR"

echo ">>> Installing llama-server into runtime dir: $RUNTIME_DIR"
echo ">>> Project root : $ROOT_DIR"
echo ">>> Models dir   : $MODELS_DIR"
echo ">>> Logs dir     : $LOG_DIR"
echo ">>> Virtualenv   : $VENV_DIR"
echo

###############################################################################
# 1) Create config.env (only if missing) with absolute paths
###############################################################################
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo ">>> Creating default config at $CONFIG_FILE"

  # Generate a random API key if possible
  if command -v openssl >/dev/null 2>&1; then
    API_KEY_GENERATED="$(openssl rand -hex 32)"
  else
    API_KEY_GENERATED="llama-$(date +%s)-$RANDOM"
  fi

  cat > "$CONFIG_FILE" <<EOF
# llama-server configuration

# Root directory (project root)
LLAMA_SERVER_ROOT="$ROOT_DIR"

# Runtime directory (holds venv, logs, config)
LLAMA_SERVER_RUNTIME_DIR="$RUNTIME_DIR"

# Virtualenv path
LLAMA_SERVER_VENV="$VENV_DIR"

# Where GGUF models live
LLAMA_SERVER_MODELS_DIR="$MODELS_DIR"

# Logs
LLAMA_SERVER_LOG_DIR="$LOG_DIR"

# Host/port for the OpenAI-compatible server (backend)
LLAMA_SERVER_HOST="127.0.0.1"
LLAMA_SERVER_PORT="8002"

# Default model settings
LLAMA_SERVER_DEFAULT_N_CTX=8192
LLAMA_SERVER_DEFAULT_N_GPU_LAYERS=-1

# API key required for all requests (Authorization: Bearer <key>)
LLAMA_SERVER_API_KEY="$API_KEY_GENERATED"

# Auth proxy (optional)
LLAMA_PROXY_ENABLED="0"
LLAMA_PROXY_HOST="0.0.0.0"
LLAMA_PROXY_PORT="8001"
LLAMA_SERVER_BACKEND_URL="http://127.0.0.1:8002"
# Rate limiting (per user)
LLAMA_PROXY_RATE_LIMIT="60"
LLAMA_PROXY_RATE_WINDOW_SECONDS="60"
# Database config lives in .env via POSTGRES_AUTH_*

# PID file for the running server
LLAMA_SERVER_PID_FILE="\$LLAMA_SERVER_RUNTIME_DIR/llama_server.pid"

# Optional: pin GPUs (example: "0" or "0,1")
LLAMA_SERVER_CUDA_VISIBLE_DEVICES=""
EOF

  echo ">>> Generated API key (store this somewhere safe): $API_KEY_GENERATED"
  echo
else
  echo ">>> Existing config found at $CONFIG_FILE (leaving it as-is)"
  echo
fi

###############################################################################
# 1a) Migrate legacy defaults to proxy-on-8001 layout (if unchanged)
###############################################################################
if [[ -f "$CONFIG_FILE" ]]; then
  update_config_if_matches() {
    local key="$1"
    local from="$2"
    local to="$3"
    if rg -q "^${key}=\"${from}\"$" "$CONFIG_FILE"; then
      python3 - <<PY
from pathlib import Path
path = Path(r"""$CONFIG_FILE""")
text = path.read_text()
text = text.replace('${key}="${from}"', '${key}="${to}"')
path.write_text(text)
PY
    fi
  }
  update_config_if_matches "LLAMA_SERVER_HOST" "0.0.0.0" "127.0.0.1"
  update_config_if_matches "LLAMA_SERVER_PORT" "8000" "8002"
  update_config_if_matches "LLAMA_PROXY_PORT" "8000" "8001"
  update_config_if_matches "LLAMA_SERVER_BACKEND_URL" "http://127.0.0.1:8000" "http://127.0.0.1:8002"
fi

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
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

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -E "[:.]$port$" >/dev/null 2>&1
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "[\.:]$port[[:space:]]+.*LISTEN" >/dev/null 2>&1
    return $?
  fi
  return 1
}

find_free_port() {
  local port="$1"
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [[ ! -f "$file" ]]; then
    echo "$key=$value" > "$file"
    return 0
  fi
  if rg -q "^${key}=" "$file"; then
    python3 - <<PY
from pathlib import Path
path = Path(r"""$file""")
text = path.read_text()
lines = []
for line in text.splitlines():
    if line.startswith("$key="):
        lines.append("$key=$value")
    else:
        lines.append(line)
path.write_text("\\n".join(lines) + "\\n")
PY
  else
    echo "$key=$value" >> "$file"
  fi
}

###############################################################################
# 1b) Start local Postgres (docker compose) if available
###############################################################################
load_env_file "$ENV_FILE"
POSTGRES_AUTH_PORT="${POSTGRES_AUTH_PORT:-5432}"

if [[ "${LLAMA_SKIP_DOCKER_DB:-0}" == "1" ]]; then
  echo ">>> Skipping Postgres startup (LLAMA_SKIP_DOCKER_DB=1)."
  echo
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  local_recreate=""
  if port_in_use "$POSTGRES_AUTH_PORT"; then
    new_port="$(find_free_port 15432)"
    set_env_value "$ENV_FILE" "POSTGRES_AUTH_PORT" "$new_port"
    POSTGRES_AUTH_PORT="$new_port"
    echo ">>> Port in use; switched POSTGRES_AUTH_PORT to $POSTGRES_AUTH_PORT in .env."
    local_recreate="--force-recreate"
  fi
  echo ">>> Starting Postgres via docker compose..."
  docker compose -f "$ROOT_DIR/docker-compose.yml" up -d $local_recreate postgres
  echo
else
  echo ">>> Docker compose not available; skipping Postgres startup."
  echo ">>> You can start it manually with: docker compose up -d postgres"
  echo
fi

###############################################################################
# 2) Create venv + install Python deps
###############################################################################
if [[ ! -d "$VENV_DIR" ]]; then
  echo ">>> Creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

VENV_BIN="$VENV_DIR/bin"
if [[ ! -d "$VENV_BIN" ]]; then
  VENV_BIN="$VENV_DIR/Scripts"
fi

PIP_BIN="$VENV_BIN/pip"
PY_BIN="$VENV_BIN/python"
if [[ ! -x "$PIP_BIN" ]]; then
  PIP_BIN="$VENV_BIN/pip.exe"
fi
if [[ ! -x "$PY_BIN" ]]; then
  PY_BIN="$VENV_BIN/python.exe"
fi

echo ">>> Upgrading pip and installing dependencies inside venv"
"$PIP_BIN" install --upgrade pip
"$PIP_BIN" install "llama-cpp-python[server]" "huggingface_hub" "psycopg2-binary" "PyYAML"

echo

###############################################################################
# 3) Ensure we have at least one model (fallback)
###############################################################################

if ls "$MODELS_DIR"/*.gguf >/dev/null 2>&1; then
  echo ">>> Models already present in $MODELS_DIR"
  exit 0
fi

echo ">>> models/ directory is empty."
echo ">>> Attempting to download fallback TinyLlama 1.1B Chat (Q4_K_M GGUF) ..."
echo ">>> Source: TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF (Hugging Face)"
echo

if [[ -z "${HF_TOKEN:-}" ]] && [[ -t 0 ]]; then
  read -r -p "Optional: enter HF_TOKEN for higher rate limits (leave blank to skip): " HF_TOKEN_INPUT
  if [[ -n "$HF_TOKEN_INPUT" ]]; then
    export HF_TOKEN="$HF_TOKEN_INPUT"
  fi
fi

HFACE_CLI="$VENV_DIR/bin/huggingface-cli"
if [[ -x "$HFACE_CLI" ]]; then
  "$HFACE_CLI" download \
    TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
    tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
    --local-dir "$MODELS_DIR" \
    --local-dir-use-symlinks False
else
  "$VENV_DIR/bin/python" - <<PY
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id="TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    filename="tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    local_dir=r"""$MODELS_DIR""",
    local_dir_use_symlinks=False,
)
PY
fi

echo ">>> Fallback model downloaded into: $MODELS_DIR"
