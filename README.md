# Llamaserve

Thin wrapper around `llama_cpp.server` that runs **one GGUF model** and exposes an **OpenAI-compatible HTTP API**.

## Quick start

```bash
./runtime/install.sh
./console.sh start
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
curl -s http://0.0.0.0:8000/v1/models \
  -H "Authorization: Bearer $LLAMA_SERVER_API_KEY"
```

Chat completion:

```bash
curl -s http://0.0.0.0:8000/v1/chat/completions \
  -H "Authorization: Bearer $LLAMA_SERVER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

## Multi-user auth (Postgres proxy)

`llama_cpp.server` only supports a single API key. To support **one key per user**, run the auth proxy.

1) Configure DB and enable proxy in `runtime/config.env`:
```bash
LLAMA_PROXY_ENABLED="1"
LLAMA_SERVER_DATABASE_URL="postgresql://user:pass@localhost:5432/vectordb"
LLAMA_SERVER_HOST="127.0.0.1"
LLAMA_SERVER_BACKEND_URL="http://127.0.0.1:8000"
```

2) Bootstrap the user CLI and create users:
```bash
./bin/bootstrap_user_cli.sh
./bin/user_management_cli.sh init-db
./bin/user_management_cli.sh create-user --username alice
```

3) Start the server (this also starts the proxy when enabled):
```bash
./console.sh start
```

4) Call the proxy with the **user-specific key** (port 8001 by default):
```bash
curl -s http://0.0.0.0:8001/v1/models \
  -H "Authorization: Bearer <USER_KEY>"
```

## Notes

- When the proxy is enabled, do not share `LLAMA_SERVER_API_KEY` with users.
- `/v1/models` is the discovery endpoint for the model id.
- Rate limiting is enabled per user via `LLAMA_PROXY_RATE_LIMIT` and `LLAMA_PROXY_RATE_WINDOW_SECONDS`.
- Requests are logged to Postgres in the `llama_requests` table with latency and byte counts.

## Scope

This project is intentionally minimal:
- Runs exactly one GGUF model at a time
- Exposes an OpenAI-compatible API
- Simple CLI for start/stop/restart
- API key protection

Embedding, retrieval, RAG, and business logic live outside this repo.
