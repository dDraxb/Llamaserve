#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/runtime/config.env"
MODELS_DIR="$ROOT_DIR/models"
MODELS_CFG="$ROOT_DIR/config/models.yaml"
CONSOLE="$ROOT_DIR/console.sh"
USER_CLI="$ROOT_DIR/bin/user_management_cli.sh"
BOOTSTRAP_CLI="$ROOT_DIR/bin/bootstrap_user_cli.sh"
RUNTIME_PYTHON="$ROOT_DIR/runtime/.venv/bin/python"

WITH_MULTI=1
WITH_PROXY=1
MODE="full"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci)
      MODE="ci"
      WITH_MULTI=0
      WITH_PROXY=0
      ;;
    --full)
      MODE="full"
      ;;
    --no-multi) WITH_MULTI=0 ;;
    --no-proxy) WITH_PROXY=0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--ci|--full] [--no-multi] [--no-proxy]" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x "$CONSOLE" ]]; then
  echo "Missing executable: $CONSOLE" >&2
  exit 1
fi

if [[ "$MODE" == "ci" ]]; then
  echo "[1/4] Script syntax"
  bash -n "$ROOT_DIR/console.sh"
  bash -n "$ROOT_DIR/runtime/install.sh"
  bash -n "$ROOT_DIR/bin/"*.sh

  echo "[2/4] Console contract"
  "$CONSOLE" -h >/dev/null
  "$CONSOLE" status >/dev/null

  echo "[3/4] YAML contract"
  if python3 -c "import yaml" >/dev/null 2>&1; then
    python3 - <<PY
import pathlib, yaml
root = pathlib.Path(r"""$ROOT_DIR""")
for p in [
    root / "config" / "models.yaml.example",
    root / "config" / "proxy_routes.yaml.example",
]:
    yaml.safe_load(p.read_text())
print("yaml_ok")
PY
  else
    rg -n "^models:|^instances:" "$ROOT_DIR/config/models.yaml.example" >/dev/null
    rg -n "^routes:" "$ROOT_DIR/config/proxy_routes.yaml.example" >/dev/null
    echo "yaml_module_missing_fallback_ok"
  fi

  echo "[4/4] PASS"
  echo "Smoke test succeeded (ci mode)."
  exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing runtime config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${LLAMA_SERVER_API_KEY:-}" ]]; then
  echo "LLAMA_SERVER_API_KEY is missing in $CONFIG_FILE" >&2
  exit 1
fi

MODEL_PICK="$(find "$MODELS_DIR" -maxdepth 2 -type f -name '*.gguf' | head -n 1 || true)"
if [[ -z "$MODEL_PICK" ]]; then
  echo "No .gguf model found under $MODELS_DIR" >&2
  exit 1
fi
MODEL_BASENAME="$(basename "$MODEL_PICK")"
SINGLE_TARGET="$MODEL_BASENAME"

BACKEND_HOST="${LLAMA_SERVER_HOST:-127.0.0.1}"
BACKEND_PORT="${LLAMA_SERVER_PORT:-8002}"
BACKEND_URL="http://${BACKEND_HOST}:${BACKEND_PORT}"
SINGLE_API_KEY="${LLAMA_SERVER_API_KEY:-}"

if [[ -f "$MODELS_CFG" && -x "$RUNTIME_PYTHON" ]]; then
  first_entry="$("$RUNTIME_PYTHON" - <<PY
import pathlib
import sys
import yaml

path = pathlib.Path(r"""$MODELS_CFG""")
data = yaml.safe_load(path.read_text()) or {}
entries = data.get("models") or data.get("instances") or []
if not entries:
    raise SystemExit(0)
entry = entries[0]
print("|".join([
    str(entry.get("name") or "").strip(),
    str(entry.get("model") or "").strip(),
    str(entry.get("host") or "").strip(),
    str(entry.get("port") or "").strip(),
    str(entry.get("api_key") or "").strip(),
]))
PY
)"
  if [[ -n "$first_entry" ]]; then
    IFS='|' read -r single_name single_model single_host single_port single_api_key <<<"$first_entry"
    if [[ -n "$single_name" ]]; then
      SINGLE_TARGET="$single_name"
    elif [[ -n "$single_model" ]]; then
      SINGLE_TARGET="$single_model"
    fi
    if [[ -n "$single_model" ]]; then
      MODEL_BASENAME="$(basename "$single_model")"
    fi
    if [[ -n "$single_host" ]]; then
      BACKEND_HOST="$single_host"
    fi
    if [[ -n "$single_port" ]]; then
      BACKEND_PORT="$single_port"
    fi
    if [[ -n "$single_api_key" ]]; then
      SINGLE_API_KEY="$single_api_key"
    fi
    BACKEND_URL="http://${BACKEND_HOST}:${BACKEND_PORT}"
  fi
fi

TEMP_USER=""
TEMP_TOKEN=""
MODELS_CFG_BAK=""

cleanup() {
  set +e
  if [[ -n "$TEMP_USER" ]] && [[ -x "$USER_CLI" ]]; then
    "$USER_CLI" delete-user --username "$TEMP_USER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MODELS_CFG_BAK" ]] && [[ -f "$MODELS_CFG_BAK" ]]; then
    mv -f "$MODELS_CFG_BAK" "$MODELS_CFG" || true
  fi
  "$CONSOLE" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[1/6] Reset state"
"$CONSOLE" stop >/dev/null 2>&1 || true

echo "[2/6] Single mode start + status"
"$CONSOLE" start single "$SINGLE_TARGET" >/dev/null
sleep 2
single_status="$("$CONSOLE" status)"
echo "$single_status" | rg -q "Server status: RUNNING"
if [[ -f "$ROOT_DIR/runtime/llama_server.host" ]]; then
  BACKEND_HOST="$(cat "$ROOT_DIR/runtime/llama_server.host")"
fi
if [[ -f "$ROOT_DIR/runtime/llama_server.port" ]]; then
  BACKEND_PORT="$(cat "$ROOT_DIR/runtime/llama_server.port")"
fi
if [[ -f "$ROOT_DIR/runtime/llama_server.model" ]]; then
  MODEL_BASENAME="$(basename "$(cat "$ROOT_DIR/runtime/llama_server.model")")"
fi
BACKEND_URL="http://${BACKEND_HOST}:${BACKEND_PORT}"

echo "[3/6] Backend API checks"
curl -sS --max-time 20 "$BACKEND_URL/v1/models" \
  -H "Authorization: Bearer $SINGLE_API_KEY" >/dev/null
curl -sS --max-time 30 "$BACKEND_URL/v1/chat/completions" \
  -H "Authorization: Bearer $SINGLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_BASENAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":30}" >/dev/null

if [[ "$WITH_PROXY" -eq 1 ]]; then
  echo "[4/6] Proxy auth checks (if docker proxy is running)"
  if command -v docker >/dev/null 2>&1 && docker compose -f "$ROOT_DIR/docker-compose.yml" ps --status running proxy 2>/dev/null | grep -q "proxy"; then
    if [[ -x "$BOOTSTRAP_CLI" && -x "$USER_CLI" ]]; then
      "$BOOTSTRAP_CLI" >/dev/null
      TEMP_USER="smoke_$(date +%s)"
      user_out="$("$USER_CLI" create-user --username "$TEMP_USER")"
      TEMP_TOKEN="$(echo "$user_out" | awk -F': ' '/API key/{print $2}' | tr -d '\r')"
      if [[ -z "$TEMP_TOKEN" ]]; then
        echo "Failed to parse temp API token from user CLI output." >&2
        exit 1
      fi
      curl -sS --max-time 20 "http://127.0.0.1:8001/v1/models" \
        -H "Authorization: Bearer $TEMP_TOKEN" >/dev/null
      curl -sS --max-time 30 "http://127.0.0.1:8001/v1/chat/completions" \
        -H "Authorization: Bearer $TEMP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_BASENAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":20}" >/dev/null
    else
      echo "Skipping proxy auth checks: user CLI scripts missing."
    fi
  else
    echo "Skipping proxy auth checks: docker proxy service is not running."
  fi
else
  echo "[4/6] Proxy checks skipped (--no-proxy)"
fi

if [[ "$WITH_MULTI" -eq 1 ]]; then
  echo "[5/6] Multi mode checks (temporary safe config)"
  "$CONSOLE" stop >/dev/null 2>&1 || true
  if [[ -f "$MODELS_CFG" ]]; then
    MODELS_CFG_BAK="${MODELS_CFG}.bak.$(date +%s)"
    cp "$MODELS_CFG" "$MODELS_CFG_BAK"
  fi
  cat > "$MODELS_CFG" <<EOF
models:
  - name: smoke_multi
    model: $MODEL_BASENAME
    host: 127.0.0.1
    port: ${LLAMA_SERVER_PORT:-8002}
    n_ctx: 2048
    n_gpu_layers: 0
    chat_format: ""
EOF
  "$CONSOLE" start multi --no-prompt >/dev/null
  sleep 2
  multi_status="$("$CONSOLE" status)"
  echo "$multi_status" | rg -q "Mode : multi"
  curl -sS --max-time 20 "$BACKEND_URL/v1/models" \
    -H "Authorization: Bearer $LLAMA_SERVER_API_KEY" >/dev/null
else
  echo "[5/6] Multi checks skipped (--no-multi)"
fi

echo "[6/6] PASS"
echo "Smoke test succeeded."
