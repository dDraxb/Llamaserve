# Llamaserve

Thin wrapper around `llama_cpp.server` that runs **one GGUF model** and exposes an **OpenAI-compatible HTTP API**.

## Quick start

```bash
./runtime/install.sh
./console.sh start single
```

## Layout

- `config/` for multi-model and proxy routing YAML.
- `logs/` for server and proxy logs.
- `data/postgres/` for Postgres data (auth + request logs).

## Multi-model (multiple servers)

This project is single-model by default. To run **multiple models**, start multiple `llama_cpp.server` processes via the CLI.

1) Create a config:
```bash
cp config/models.yaml.example config/models.yaml
```

2) Edit `config/models.yaml` to map models to GPUs and ports.

3) Start all:
```bash
./console.sh start multi
```

4) Status:
```bash
./console.sh status-multi
```

Each entry maps to a separate server instance; use distinct ports and optional `cuda_visible_devices`.
`restart`, `stop`, and `status` operate on the currently running mode (single or multi).
To route by model through the proxy, create `config/proxy_routes.yaml` from the example and map model IDs to backend URLs.

## Add models (GGUF only)

Models must be **GGUF** files placed in `models/`.

For sharded GGUF (e.g., `*-00001-of-00003.gguf`), place all shards in a subfolder under `models/`. The CLI will show the folder as a single “sharded” option and pick the `00001` shard automatically.
If shards are placed directly in `models/`, the CLI will still group them, but it will warn and recommend moving them into a subfolder to avoid clutter and accidental selection errors.
If a model emits raw `<|channel|>` / `<|assistant|>` markers, set `chat_format` per instance in `config/models.yaml` to the correct template for that GGUF. If `chat_format` is omitted, llama-cpp uses its default/auto behavior.

Example (Hugging Face CLI using `hf`):
```bash
HF_TOKEN=INSERT_token \
  hf download bartowski/openai_gpt-oss-20b-GGUF \
    --include "openai_gpt-oss-20b-Q4_K_M.gguf" \
    --local-dir models/ \
    --local-dir-use-symlinks False
```

## API key

The API key is stored in `runtime/config.env` as `LLAMA_SERVER_API_KEY`.
Pass it as a bearer token (direct access):

```bash
export LLAMA_SERVER_API_KEY=...
```

## Test commands

List models:

```bash
curl -s http://127.0.0.1:8001/v1/models \
  -H "Authorization: Bearer $LLAMA_SERVER_API_KEY"
```

Chat completion:

```bash
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Authorization: Bearer $LLAMA_SERVER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

## Multi-user auth (Postgres proxy)

`llama_cpp.server` only supports a single API key. To support **one key per user**, run the auth proxy (Docker is the default).

1) Configure DB in `.env` using `POSTGRES_AUTH_*` and keep the backend private:
```bash
LLAMA_PROXY_ENABLED="1"
LLAMA_SERVER_HOST="127.0.0.1"
LLAMA_SERVER_BACKEND_URL="http://127.0.0.1:8002"
```

If you want a local Postgres, use the included compose file:
```bash
docker compose up -d postgres
```

Defaults for local Postgres are in `.env.example`. Copy it to `.env` and adjust as needed.
The compose file reads `POSTGRES_AUTH_*` variables.
If the port is already in use, `runtime/install.sh` picks a free port starting at 15432 and updates `.env`.

Run the proxy in Docker (recommended on macOS):
```bash
docker compose up -d proxy
```
This runs the auth proxy inside Docker and avoids local network permission issues. The proxy will still be reachable on port 8001.
It connects to Postgres over the Docker network (port 5432 inside the container), independent of host port mappings.
Use `127.0.0.1` for local access and your LAN IP for remote clients; `0.0.0.0` is a bind address, not a client address.
When using the Docker proxy, backend routes are rewritten to `host.docker.internal` automatically.

2) Bootstrap the user CLI and create users:
```bash
./bin/bootstrap_user_cli.sh
./bin/user_management_cli.sh init-db
./bin/user_management_cli.sh create-user --username alice
```

3) Start the backend server:
```bash
./console.sh start single
```

4) Call the proxy with the **user-specific key** (port 8001 by default):
```bash
curl -s http://127.0.0.1:8001/v1/models \
  -H "Authorization: Bearer <USER_KEY>"
```

Local proxy is still available for development via `./console.sh start-proxy`, but Docker avoids macOS localhost permission issues and keeps DB access consistent.

## Notes

- When the proxy is enabled, do not share `LLAMA_SERVER_API_KEY` with users.
- `/v1/models` is the discovery endpoint for the model id.
- Rate limiting is enabled per user via `LLAMA_PROXY_RATE_LIMIT` and `LLAMA_PROXY_RATE_WINDOW_SECONDS`.
- Requests are logged to Postgres in the `llama_requests` table with latency and byte counts.
- Conversation management is client-side: send the full (or summarized) message history with each request.
- OpenAI compatibility is best-effort; optional parameters may be ignored or unsupported.
- The OpenAI `/v1/completions` API is legacy; prefer `/v1/chat/completions`. citeturn0search0

## Network layout examples (proxy on 8001)

Single model (proxy is public entrypoint):
```bash
# runtime/config.env
LLAMA_PROXY_ENABLED=1
LLAMA_SERVER_HOST=127.0.0.1
LLAMA_SERVER_PORT=8002
LLAMA_PROXY_HOST=0.0.0.0
LLAMA_PROXY_PORT=8001
LLAMA_SERVER_BACKEND_URL=http://127.0.0.1:8002
```

Multi-model (proxy routes by model):
```yaml
# config/models.yaml
instances:
  - name: gpu0_tinyllama
    model: tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf
    host: 127.0.0.1
    port: 8002
    cuda_visible_devices: "0"
    n_ctx: 8192
    n_gpu_layers: -1

  - name: gpu1_gptoss
    model: openai_gpt-oss-20b-Q4_K_M.gguf
    host: 127.0.0.1
    port: 8003
    cuda_visible_devices: "1"
    n_ctx: 8192
    n_gpu_layers: -1
```

```yaml
# config/proxy_routes.yaml
routes:
  - model: tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf
    backend_url: http://127.0.0.1:8002
  - model: openai_gpt-oss-20b-Q4_K_M.gguf
    backend_url: http://127.0.0.1:8003
```

## OpenAI API parameter support (chat/completions)

This server uses `llama_cpp.server` and primarily targets `/v1/chat/completions`. Support depends on model/chat format; see notes below. The list reflects parameters exposed by the llama-cpp-python API. citeturn11view0

| Parameter | Supported | Notes |
| --- | --- | --- |
| `model` | Yes | Must match `/v1/models` id. |
| `messages` | Yes | Required for chat. |
| `stream` | Yes | Streaming supported. |
| `temperature` | Yes | Sampling control. |
| `top_p` | Yes | Nucleus sampling. |
| `top_k` | Yes | Top-k sampling. |
| `min_p` | Yes | Minimum p sampling. |
| `typical_p` | Yes | Typical sampling. |
| `stop` | Yes | String or list. |
| `max_tokens` | Yes | May be limited by context size. |
| `presence_penalty` | Yes | Sampling penalty. |
| `frequency_penalty` | Yes | Sampling penalty. |
| `repeat_penalty` | Yes | Sampling penalty. |
| `seed` | Yes | Determinism (best-effort). |
| `logit_bias` | Yes | Bias token probabilities. |
| `logprobs` / `top_logprobs` | Yes | Logprobs support. |
| `response_format` | Yes* | JSON/JSON schema supported by llama-cpp-python; model-dependent. citeturn6search8 |
| `functions` / `function_call` | Yes* | Requires function-calling models and chat_format (e.g., functionary). citeturn7view0 |
| `tools` / `tool_choice` | Yes* | Same requirement as functions. citeturn11view0turn7view0 |

*If a feature depends on a specific model/chat format, the server may accept the parameter but ignore it.*

## Scope

This project is intentionally minimal:
- Runs exactly one GGUF model at a time
- Exposes an OpenAI-compatible API
- Simple CLI for start/stop/restart
- API key protection

Embedding, retrieval, RAG, and business logic live outside this repo.
