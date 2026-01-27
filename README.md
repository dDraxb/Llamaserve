# Llamaserve

Thin wrapper around `llama_cpp.server` that runs **one GGUF model** and exposes an **OpenAI-compatible HTTP API**.

## Quick start

```bash
./runtime/install.sh
./console.sh start
```

## Add models (GGUF only)

Models must be **GGUF** files placed in `models/`.

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

1) Configure DB in `.env` using `POSTGRES_AUTH_*` and enable proxy in `runtime/config.env`:
```bash
LLAMA_PROXY_ENABLED="1"
LLAMA_SERVER_HOST="127.0.0.1"
LLAMA_SERVER_BACKEND_URL="http://127.0.0.1:8000"
```

If you want a local Postgres, use the included compose file and set the URL in `runtime/config.env`:
```bash
docker compose up -d postgres
```

Defaults for local Postgres are in `.env.example`. Copy it to `.env` and adjust as needed.
The compose file reads `POSTGRES_AUTH_*` variables.

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
- Conversation management is client-side: send the full (or summarized) message history with each request.
- OpenAI compatibility is best-effort; optional parameters may be ignored or unsupported.
- The OpenAI `/v1/completions` API is legacy; prefer `/v1/chat/completions`. citeturn0search0

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
