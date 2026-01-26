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

# Host/port for the OpenAI-compatible server
LLAMA_SERVER_HOST="0.0.0.0"
LLAMA_SERVER_PORT="8000"

# Default model settings
LLAMA_SERVER_DEFAULT_N_CTX=8192
LLAMA_SERVER_DEFAULT_N_GPU_LAYERS=-1

# API key required for all requests (Authorization: Bearer <key>)
LLAMA_SERVER_API_KEY="$API_KEY_GENERATED"

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
# 2) Create venv + install Python deps
###############################################################################
if [[ ! -d "$VENV_DIR" ]]; then
  echo ">>> Creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

echo ">>> Upgrading pip and installing dependencies inside venv"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install "llama-cpp-python[server]" "huggingface_hub"

echo

###############################################################################
# 3) Ensure we have at least one model (fallback)
###############################################################################

if [[ -n "$(ls -A "$MODELS_DIR" 2>/dev/null || true)" ]]; then
  echo ">>> Models already present in $MODELS_DIR"
  exit 0
fi

echo ">>> models/ directory is empty."
echo ">>> Attempting to download fallback TinyLlama 1.1B Chat (Q4_K_M GGUF) ..."
echo ">>> Source: TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF (Hugging Face)"

HFACE_CLI="$VENV_DIR/bin/huggingface-cli"
if [[ -x "$HFACE_CLI" ]]; then
  "$HFACE_CLI" download \
    TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
    TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf \
    --local-dir "$MODELS_DIR" \
    --local-dir-use-symlinks False
else
  "$VENV_DIR/bin/python" -m huggingface_hub.cli download \
    TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
    TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf \
    --local-dir "$MODELS_DIR" \
    --local-dir-use-symlinks False
fi

echo ">>> Fallback model downloaded into: $MODELS_DIR"
