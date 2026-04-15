#!/usr/bin/env bash

# Shared server + model catalog helpers for console.sh

check_metal_backend_health() {
  local model_path="$1"
  local disable_metal="$2"
  local probe_log="$LLAMA_SERVER_LOG_DIR/llama_metal_probe.log"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi
  if is_truthy "$disable_metal" || [[ "${LLAMA_SKIP_METAL_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  "$PYTHON_BIN" - <<PY >"$probe_log" 2>&1
from llama_cpp import Llama
Llama(
    model_path=r"""$model_path""",
    n_ctx=32,
    n_gpu_layers=1,
    vocab_only=True,
    verbose=False,
)
print("METAL_HEALTH_OK")
PY
  local rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q "METAL_HEALTH_OK" "$probe_log"; then
    return 0
  fi

  err "Metal backend health check failed before startup."
  if grep -qi "picking default device: (null)\|failed to create command queue\|failed to initialize Metal backend" "$probe_log"; then
    err "Metal is unavailable in this session (device init failed)."
  fi
  err "See: $probe_log"
  err "Fallback options:"
  err "  1) Re-run from a normal logged-in GUI terminal session."
  err "  2) Start with --disable-metal (CPU mode, slower)."
  err "  3) Set LLAMA_SKIP_METAL_CHECK=1 only for explicit debugging."
  return 1
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

resolve_support_file_path() {
  local input_path="$1"
  if [[ -z "$input_path" ]]; then
    return 0
  fi

  if [[ -f "$input_path" ]]; then
    printf '%s\n' "$input_path"
    return 0
  fi

  if [[ -f "$ROOT_DIR/$input_path" ]]; then
    printf '%s\n' "$ROOT_DIR/$input_path"
    return 0
  fi

  printf '%s\n' "$input_path"
}

validate_chat_handler_requirements() {
  local name="$1"
  local chat_format="$2"
  local hf_pretrained_model_name_or_path="$3"
  local hf_tokenizer_config_path="$4"
  local resolved_hf_tokenizer_config_path="$5"

  if [[ "$chat_format" == "hf-autotokenizer" ]]; then
    if [[ -z "$hf_pretrained_model_name_or_path" ]]; then
      err "Instance [$name] requires hf_pretrained_model_name_or_path when chat_format=hf-autotokenizer."
      return 1
    fi
  fi

  if [[ "$chat_format" == "hf-tokenizer-config" ]]; then
    if [[ -z "$hf_tokenizer_config_path" ]]; then
      err "Instance [$name] requires hf_tokenizer_config_path when chat_format=hf-tokenizer-config."
      return 1
    fi
    if [[ ! -f "$resolved_hf_tokenizer_config_path" ]]; then
      err "Instance [$name] hf_tokenizer_config_path not found: $hf_tokenizer_config_path"
      return 1
    fi
  fi

  if [[ "$chat_format" == "functionary-v1" ]] || [[ "$chat_format" == "functionary-v2" ]]; then
    if [[ -z "$hf_pretrained_model_name_or_path" ]]; then
      err "Instance [$name] requires hf_pretrained_model_name_or_path when chat_format=$chat_format."
      return 1
    fi
    if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("transformers") else 1)
PY
    then
      err "Instance [$name] needs the Python package 'transformers' for $chat_format."
      err "Re-run: ./runtime/install.sh"
      return 1
    fi
  fi
}

is_instance_running() {
  local name="$1"
  local pid_file
  pid_file="$(instance_pid_file "$name")"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && is_llama_process "$pid"; then
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
  local chat_format="$9"
  local no_mmap="${10:-}"
  local flash_attn="${11:-}"
  local disable_metal="${12:-}"
  local hf_pretrained_model_name_or_path="${13:-}"
  local hf_tokenizer_config_path="${14:-}"
  local hf_model_repo_id="${15:-}"

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
  local effective_chat_format="$chat_format"
  local effective_no_mmap="$no_mmap"
  local effective_flash_attn="$flash_attn"
  local effective_disable_metal="$disable_metal"
  local effective_hf_pretrained_model_name_or_path="$hf_pretrained_model_name_or_path"
  local effective_hf_tokenizer_config_path="$hf_tokenizer_config_path"
  local effective_hf_model_repo_id="$hf_model_repo_id"

  [[ -z "$effective_host" ]] && effective_host="$LLAMA_SERVER_HOST"
  [[ -z "$effective_port" ]] && effective_port="$LLAMA_SERVER_PORT"
  [[ -z "$effective_n_ctx" ]] && effective_n_ctx="$LLAMA_SERVER_DEFAULT_N_CTX"
  [[ -z "$effective_n_gpu_layers" ]] && effective_n_gpu_layers="$LLAMA_SERVER_DEFAULT_N_GPU_LAYERS"
  [[ -z "$effective_chat_format" ]] && effective_chat_format="$LLAMA_SERVER_CHAT_FORMAT"
  [[ -z "$effective_disable_metal" ]] && effective_disable_metal="$LLAMA_SERVER_DISABLE_METAL"
  [[ -z "$effective_hf_pretrained_model_name_or_path" ]] && effective_hf_pretrained_model_name_or_path="${LLAMA_SERVER_HF_PRETRAINED_MODEL_NAME_OR_PATH:-}"
  [[ -z "$effective_hf_tokenizer_config_path" ]] && effective_hf_tokenizer_config_path="${LLAMA_SERVER_HF_TOKENIZER_CONFIG_PATH:-}"
  [[ -z "$effective_hf_model_repo_id" ]] && effective_hf_model_repo_id="${LLAMA_SERVER_HF_MODEL_REPO_ID:-}"
  effective_hf_tokenizer_config_path="$(resolve_support_file_path "$effective_hf_tokenizer_config_path")"
  validate_chat_handler_requirements \
    "$name" \
    "$effective_chat_format" \
    "$effective_hf_pretrained_model_name_or_path" \
    "$hf_tokenizer_config_path" \
    "$effective_hf_tokenizer_config_path"
  if is_truthy "$effective_disable_metal" && [[ "$effective_n_gpu_layers" == "-1" ]]; then
    # Disable full GPU offload when Metal is disabled on macOS.
    effective_n_gpu_layers="0"
  fi
  check_metal_backend_health "$model_path" "$effective_disable_metal"

  info "Starting instance [$name]..."
  info "  Model: $model_path"
  info "  Bind : $effective_host"
  info "  Port : $effective_port"
  info "  Log  : $log_file"

  local -a chat_format_args=()
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

  local -a server_cmd=(
    "$PYTHON_BIN" -m llama_cpp.server
    --model "$model_path"
    --host "$effective_host"
    --port "$effective_port"
    --n_ctx "$effective_n_ctx"
    --n_gpu_layers "$effective_n_gpu_layers"
    --api_key "$effective_api_key"
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
  } >>"$log_file"

  local -a env_cmd=()
  if [[ -n "$gpus" ]]; then
    env_cmd+=(CUDA_VISIBLE_DEVICES="$gpus")
  fi
  if is_truthy "$effective_disable_metal"; then
    env_cmd+=(GGML_METAL=0 LLAMA_METAL=0)
  fi

  if [[ "${#env_cmd[@]}" -gt 0 ]]; then
    env "${env_cmd[@]}" "${clean_cmd[@]}" >>"$log_file" 2>&1 &
  else
    "${clean_cmd[@]}" >>"$log_file" 2>&1 &
  fi

  echo $! > "$(instance_pid_file "$name")"
  echo "$model_path" > "$(instance_model_file "$name")"
  info "Instance [$name] started with PID $(cat "$(instance_pid_file "$name")")"

  local started_pid
  started_pid="$(cat "$(instance_pid_file "$name")")"
  local attempts=0
  while [[ "$attempts" -lt 12 ]]; do
    if ! kill -0 "$started_pid" 2>/dev/null; then
      break
    fi
    if is_pid_listening_on_port "$started_pid" "$effective_port"; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.25
  done
  if ! kill -0 "$started_pid" 2>/dev/null || ! is_pid_listening_on_port "$started_pid" "$effective_port"; then
    err "Instance [$name] exited early. Check log: $log_file"
    tail -n 20 "$log_file" >&2 || true
    rm -f "$(instance_pid_file "$name")"
    return 1
  fi
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
instances = data.get("models") or data.get("instances") or []
def get_value(obj, key):
    if key in obj and obj.get(key) is not None:
        return str(obj.get(key)).strip()
    return ""
for inst in instances:
    name = get_value(inst, "name")
    if not name:
        continue
    model = get_value(inst, "model")
    host = get_value(inst, "host")
    port = get_value(inst, "port")
    gpus = get_value(inst, "cuda_visible_devices")
    n_ctx = get_value(inst, "n_ctx")
    n_gpu_layers = get_value(inst, "n_gpu_layers")
    api_key = get_value(inst, "api_key")
    chat_format = get_value(inst, "chat_format")
    no_mmap = get_value(inst, "no_mmap").lower()
    flash_attn = get_value(inst, "flash_attn").lower()
    disable_metal = get_value(inst, "disable_metal").lower()
    hf_pretrained_model_name_or_path = get_value(inst, "hf_pretrained_model_name_or_path")
    hf_tokenizer_config_path = get_value(inst, "hf_tokenizer_config_path")
    hf_model_repo_id = get_value(inst, "hf_model_repo_id")
    def to_flag(value):
        return "1" if value in ("1", "true", "yes", "on") else ""
    print("|".join([
        name,
        model,
        host,
        port,
        gpus,
        n_ctx,
        n_gpu_layers,
        api_key,
        chat_format,
        to_flag(no_mmap),
        to_flag(flash_attn),
        to_flag(disable_metal),
        hf_pretrained_model_name_or_path,
        hf_tokenizer_config_path,
        hf_model_repo_id,
    ]))
PY
}

start_multi() {
  ensure_venv_and_deps
  ensure_at_least_one_model
  mkdir -p "$INSTANCES_DIR" "$LLAMA_SERVER_LOG_DIR"

  local no_prompt=0
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --no-prompt)
        no_prompt=1
        ;;
      *)
        err "Unknown option for start multi: $arg"
        usage
        exit 1
        ;;
    esac
    shift || true
  done

  local -a entries=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && entries+=("$line")
  done < <(parse_multi_config)

  if [[ "${#entries[@]}" -eq 0 ]]; then
    err "No models defined in $LLAMA_MULTI_CONFIG"
    exit 1
  fi

  local selection=""
  if [[ -t 0 ]] && [[ "$no_prompt" -eq 0 ]]; then
    echo "Available models:"
    local i
    for i in "${!entries[@]}"; do
      IFS='|' read -r name model host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"${entries[$i]}"
      printf "  [%d] %s (%s)\n" "$((i + 1))" "$name" "$(basename "$model")"
    done
    while true; do
      read -r -p "Select models [e.g., 1,2 or all]: " selection
      [[ -z "$selection" ]] && selection="all"
      if [[ "$selection" =~ ^(all|a|\*)$ ]]; then
        selection="all"
        break
      fi
      local valid=1
      local token
      for token in $(echo "$selection" | tr ',' ' '); do
        if [[ ! "$token" =~ ^[0-9]+$ ]] || ((token < 1 || token > ${#entries[@]})); then
          valid=0
          break
        fi
      done
      if [[ "$valid" -eq 1 ]]; then
        break
      fi
      err "Invalid selection."
    done
  else
    selection="all"
  fi

  local idx
  for idx in $(seq 1 "${#entries[@]}"); do
    if [[ "$selection" != "all" ]]; then
      local found=0
      local token
      for token in $(echo "$selection" | tr ',' ' '); do
        if [[ "$token" -eq "$idx" ]]; then
          found=1
          break
        fi
      done
      [[ "$found" -eq 1 ]] || continue
    fi
    IFS='|' read -r name model host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id <<<"${entries[$((idx - 1))]}"
    if is_instance_running "$name"; then
      err "Instance already running, skipping: $name"
      continue
    fi
    start_instance "$name" "$model" "$host" "$port" "$gpus" "$n_ctx" "$n_gpu_layers" "$api_key" "$chat_format" "$no_mmap" "$flash_attn" "$disable_metal" "$hf_pretrained_model_name_or_path" "$hf_tokenizer_config_path" "$hf_model_repo_id"
  done
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
  while IFS='|' read -r name model host port gpus n_ctx n_gpu_layers api_key chat_format no_mmap flash_attn disable_metal hf_pretrained_model_name_or_path hf_tokenizer_config_path hf_model_repo_id; do
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
    if find "$dir" -maxdepth 1 -type f -name "*.gguf" -print -quit >/dev/null 2>&1; then
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
