# agents.md

## Project Overview

This repository provides a **thin, opinionated wrapper around `llama_cpp.server`**.

It is **not** a full RAG stack, vector DB, or tool framework.  
Its only purpose is to:

- Run **exactly one GGUF LLM model** at a time
- Expose it via an **OpenAI-compatible HTTP API**
- Provide a **simple CLI** to start/stop/restart the server and choose a model
- Require an **API key** so not everyone on the network can call it

All embedding, retrieval, RAG, and “business logic” live **outside** this project.
This server is only the **orchestration / reasoning LLM**, nothing more.

---

## Directory Structure

From the perspective of this file (`agents.md`), the project root looks like:

```text
./
  console.sh        # main CLI entrypoint for humans / scripts
  agents.md         # this documentation file
  runtime/
    install.sh      # one-time installer (venv + deps + config + fallback model)
    config.env      # generated configuration (paths, host/port, API key, etc.)
    .venv/          # Python virtualenv with llama-cpp-python[server], huggingface_hub
  config/
    models.yaml     # multi-model instances
    proxy_routes.yaml # proxy routing by model
  logs/
    llama_server.log
  data/
    postgres/       # Postgres data directory
  models/
    *.gguf          # one or more GGUF LLM model files (downloaded or copied here)

Note: For sharded GGUF (e.g., `*-00001-of-00003.gguf`), place all shards in a subfolder under `models/` so the CLI shows a single “sharded” option and picks the `00001` shard.

---

## Usage (Quick Test)

1) List models (via proxy):
```bash
curl -s http://127.0.0.1:8001/v1/models \
  -H "Authorization: Bearer <USER_KEY>"
```

2) Chat completion (via proxy):
```bash
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Authorization: Bearer <USER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

---

## Multi-user Auth (Proxy)

To support one API key per user, run the Postgres-backed auth proxy (Docker default). It validates user keys and forwards to `llama_cpp.server`.

Key env vars:
- `POSTGRES_AUTH_*` in `.env` (DB config)
- `LLAMA_PROXY_ENABLED=1` in `runtime/config.env`
- `LLAMA_SERVER_HOST=127.0.0.1` (keep backend private)
- `LLAMA_PROXY_PORT=8001` (default)
- `LLAMA_PROXY_RATE_LIMIT=60` (per user)
- `LLAMA_PROXY_RATE_WINDOW_SECONDS=60`

Recommended proxy startup (Docker):
```bash
docker compose up -d proxy
```

Local proxy is still available for development via `./console.sh start-proxy`.

User CLI (see README for details):
```bash
./bin/bootstrap_user_cli.sh
./bin/user_management_cli.sh init-db
./bin/user_management_cli.sh create-user --username alice
```

Proxy logging table: `llama_requests` (username, path, status_code, duration_ms, request_bytes, response_bytes, created_at).

Conversation management is client-side; include the relevant message history with each request.
OpenAI compatibility is best-effort; optional parameters may be ignored or unsupported.
OpenAI `/v1/completions` is a legacy API; use `/v1/chat/completions` where possible. citeturn0search0

Multi-model support: use `config/models.yaml` and `./console.sh start multi` to run multiple servers (one per entry).
Proxy routing for multi-model: map model IDs to backends in `config/proxy_routes.yaml` (see example).
`restart`, `stop`, and `status` operate on the currently running mode (single or multi).

Supported chat parameters (llama-cpp-python API exposure): `model`, `messages`, `stream`, `temperature`, `top_p`, `top_k`, `min_p`, `typical_p`, `stop`, `max_tokens`, `presence_penalty`, `frequency_penalty`, `repeat_penalty`, `seed`, `logit_bias`, `logprobs`, `top_logprobs`, `response_format`, `functions`/`function_call`, `tools`/`tool_choice` (model/chat_format-dependent). citeturn11view0turn7view0
