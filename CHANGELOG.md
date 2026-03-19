# Changelog

All notable changes to this project.

## 2026-03-19

### Fixed
- `bin/smoke_test.sh` now resolves the effective single-mode backend target from the model catalog/runtime state instead of assuming port `8002`.
- Backend smoke verification now uses the actual runtime host, port, model, and API key after startup, so full smoke runs succeed when the selected single-mode instance binds to a non-default port.

## 2026-03-04

### Changed
- Refactored CLI internals into modules:
  - `bin/lib/common.sh`
  - `bin/lib/proxy.sh`
  - `bin/lib/server.sh`
- `console.sh` now acts as orchestration entrypoint sourcing shared modules.
- `bin/smoke_test.sh` supports `--ci` contract mode and `--full`.
- macOS runtime enforcement added at startup:
  - Python 3.11/3.12 required
  - `llama-cpp-python==0.2.90` enforced by default
  - explicit override via `LLAMA_ALLOW_UNPINNED=1`

### Added
- CI workflows:
  - `.github/workflows/ci.yml`
  - `.github/workflows/compatibility-matrix.yml`
- `bin/preflight.sh` and `./console.sh preflight`.
- `docs/compatibility.md`.
- Second small GGUF model support in catalog (`Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`) for real multi-instance validation.

### Fixed
- Model catalog parsing preserves explicit zero values (for example `n_gpu_layers: 0`).
- Single/multi startup now fails fast on early exit and clears stale PID files.
- Proactive macOS Metal probe with explicit diagnostics before startup.
- Native Windows shell guardrails (Git Bash/MSYS/Cygwin): fail fast with WSL2 guidance.
- Install/runtime Python version checks hardened in `runtime/install.sh`.
- Docker proxy upstream routing on Linux: added `extra_hosts: ["host.docker.internal:host-gateway"]` and made proxy backend/route host env-overridable in `docker-compose.yml`.

## 2026-03-03

- `2256ffe` refactor: single/multi handling made uniform via config and smoke test workflow.

## 2026-02-18

- `2333687` Added chat template flag and clearer multi-start documentation.

## 2026-02-17

- `34ce521` Added chat format for single start.
- `ff9dc92` Added chat template handling in output flow.
- `b8e4792` Fixed `rg` usage issues.
- `eea2296` Fixed missing `rg` dependency handling.
- `01cbd52` Added shared model support.

## 2026-02-10

- `7adf897` Fixed faulty `status` results.
- `0db621c` Added proxy support via Docker.

## 2026-02-09

- `8b7e1db` Refactored paths to reduce runtime folder clutter.

## 2026-02-06

- `df6fd64` Fixed local IP/bind wiring and improved Docker proxy behavior.

## 2026-02-02

- `cfa9516` Fixed broken Windows venv path handling.

## 2026-01-28

- `d3eb173` Added multi-server support and auth proxy integration.

## 2026-01-27

- `754b376` Fixed model selection flow at start.
- `87f81a8` Updated OpenAI API documentation.

## 2026-01-26

- `1bd912d` Fixed stream call HTTP handling.
- `a486695` Fixed proxy streaming behavior.
- `bfdd504` Added missing runtime config.
- `6a570eb` Fixed DB credential import handling.
- `651dfef` Fixed missing DB key.
- `d7ee416` Fixed Postgres connection error.
- `7c24859` Added Docker database startup.
- `9b1d97b` Added user access management via database.
- `5e7a41a` Added model download example.
- `89f000b` Added user bearer key management and request logging.
- `74d2e3b` Fixed model selection return.
- `0db0fd6` Fixed command flag handling.
- `439bc57` Fixed model selection on start.
- `b5fcea4` Added Hugging Face token prompt.
- `4fd1e14` Fixed available-model detection.
- `386b265` Fixed Hugging Face fallback path.
- `26a7aa4` Hugging Face CLI fallback debug updates.
- `1b7d478` Hugging Face command fix attempt.
- `d6cdc04` Updated `.gitignore`.
- `c810c33` Fixed broken Hugging Face fallback.
- `29ebc6a` Fixed syntax error (`unexpected end of file`).
- `f2fdb98` Initial project push.
- `7540169` Create `.gitignore`.
