# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic versioning.

## [Unreleased]

## [2026-01-26]
### Added
- Full CLI flow in `console.sh` for `start`, `stop`, `restart`, and `status`.
- Interactive model selection and optional model argument support.
- Model tracking file to improve status output.
- API key enforcement before server startup.

### Changed
- Fixed shebang placement in `console.sh` and `runtime/install.sh`.
- Completed fallback model download in `runtime/install.sh`.
- Improved logging and PID handling for server lifecycle.

### Fixed
- Resolved `console.sh` syntax errors in the venv check and status output.
- Added a `huggingface_hub` CLI fallback when `huggingface-cli` is missing.
- Corrected the fallback module invocation for Hugging Face CLI in venv.
- Switched the fallback download to `hf_hub_download` when no CLI entrypoint exists.
- Fixed fallback filename to match the repo file casing on Hugging Face.
- Updated fallback GGUF filename to `tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf`.
- Fixed model presence checks to ignore non-`.gguf` files (like `.cache`).
- Added optional interactive prompt for `HF_TOKEN` during fallback downloads.
- Auto-selects the only available GGUF model instead of prompting without a list.
- Fixed llama server flag name to `--api_key` to match `llama_cpp.server` CLI.
- Fixed single-model auto-select message contaminating the model path.
- Added `README.md` and documented test curl commands in both README and `agents.md`.
- Added Postgres-backed auth proxy with per-user API keys and a user management CLI.
- Added per-user rate limiting and request logging to the proxy.
- Expanded request logging with latency and byte counts.
- Documented GGUF-only model download example using `hf` CLI.
- Added docker-compose Postgres service for auth proxy storage.
- Moved Postgres defaults to `.env.example` and parameterized `docker-compose.yml`.
- Renamed Postgres env vars to `POSTGRES_AUTH_*` for clarity.
- Install script now auto-starts Postgres via docker compose when available.
- User CLI now loads `.env` and ignores placeholder DB URLs.
- Auth proxy now loads `.env`/`runtime/config.env` and builds DB URL from `POSTGRES_AUTH_*`.
- Proxy and CLI now use `.env` only for DB config.
- Proxy loads `runtime/config.env` for backend settings while still using `.env` for DB.
- Fixed proxy streaming to avoid `httpx.StreamClosed` errors.
- Fixed httpx streaming call for older httpx versions.
- Documented that conversation management is client-side.
- Added OpenAI chat/completions parameter support table.
- Added multi-model support via `runtime/models.csv` and new CLI commands.
- Updated `start` to require explicit `single` or `multi` mode.
- Added proxy routing via `runtime/proxy_routes.csv` and improved CLI ergonomics for multi-mode control.
- Made restart/stop/status mode-aware (no explicit mode required).
- Status now prints the current mode (single or multi).
- Status prints `Mode : none` when no servers are running.
- Switched multi-model and proxy routing configs from CSV to YAML.
- Fixed Windows venv path handling for pip/python in install and console scripts.
- Install now skips dockerized Postgres if the configured port is already in use.
- Hardened env file parsing to ignore invalid lines.
- Fixed install script local variable usage outside functions.
- Docker compose now uses `POSTGRES_AUTH_PORT`, and install auto-picks a free port when needed.
- When 5432 is busy, install now picks a free port starting at 15432.
- Standardized defaults to proxy 8001 and backend 8002 (backend remains private).
- Install now migrates legacy 8000 defaults to the 8001/8002 layout.
- Replaced `mapfile` usage for better compatibility with older bash versions.
- Fixed model selection output contaminating the model path and improved restart order with proxy enabled.
- Added optional Docker-based auth proxy service.
- Fixed Docker proxy to use Postgres container port 5432.
- Clarified bind vs client URLs in console output and aligned proxy backend default to 8002.
- Split runtime clutter into top-level `config/`, `logs/`, and `data/postgres/`.
- Updated docker-compose and defaults to use the new data/log/config paths.
- Added route host override for Docker proxy routing.
