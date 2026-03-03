#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/runtime"
CONFIG_FILE="$RUNTIME_DIR/config.env"
ENV_FILE="$ROOT_DIR/.env"

ok() { echo "[OK]  $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*"; }

is_native_windows_shell() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

check_python() {
  local py_bin=""
  local candidate
  for candidate in python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      py_bin="$(command -v "$candidate")"
      break
    fi
  done
  if [[ -z "$py_bin" ]]; then
    fail "Python not found (need 3.11 or 3.12)."
    return 1
  fi

  local version
  version="$("$py_bin" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"
  if [[ "$version" == "3.11" || "$version" == "3.12" ]]; then
    ok "Python: $py_bin ($version)"
    return 0
  fi
  fail "Python $version detected at $py_bin; supported versions are 3.11/3.12."
  return 1
}

check_port() {
  local port="$1"
  local label="$2"
  if [[ -z "$port" ]]; then
    warn "$label port not set"
    return 0
  fi
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    local owner
    owner="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR==2 {print $1 " (pid " $2 ")"}')"
    warn "$label port $port is in use by ${owner:-another process}"
  else
    ok "$label port $port is free"
  fi
}

echo "Running Llamaserve preflight checks..."

if is_native_windows_shell; then
  fail "Native Windows shell detected ($(uname -s)). Use WSL2 (Ubuntu)."
  exit 1
fi
ok "Shell/OS looks compatible"

check_python

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  ok "Found runtime config: $CONFIG_FILE"
  check_port "${LLAMA_SERVER_PORT:-}" "Backend"
  check_port "${LLAMA_PROXY_PORT:-}" "Proxy"
else
  warn "Missing runtime config: $CONFIG_FILE (run ./runtime/install.sh)"
fi

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if [[ -n "${POSTGRES_AUTH_USER:-}" && -n "${POSTGRES_AUTH_PASSWORD:-}" && -n "${POSTGRES_AUTH_DB:-}" ]]; then
    ok "Found Postgres auth settings in .env"
  else
    warn "Incomplete POSTGRES_AUTH_* in .env"
  fi
else
  warn "Missing .env (copy from .env.example)"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker compose available"
else
  warn "Docker compose not available (proxy/postgres containers unavailable)"
fi

echo "Preflight complete."
