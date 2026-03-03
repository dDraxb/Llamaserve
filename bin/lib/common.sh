#!/usr/bin/env bash

# Shared helpers for console + submodules.

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

is_truthy() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
  esac
  return 1
}

is_native_windows_shell() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_supported_shell() {
  if is_native_windows_shell; then
    err "Native Windows shell detected ($(uname -s)). Use WSL2 (Ubuntu)."
    exit 1
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

is_pid_listening_on_port() {
  local pid="$1"
  local port="$2"
  if [[ -z "$pid" ]] || [[ -z "$port" ]]; then
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$pid"
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" 2>/dev/null | grep -q "pid=$pid"
    return $?
  fi
  return 0
}
