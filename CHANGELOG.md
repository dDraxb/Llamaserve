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
