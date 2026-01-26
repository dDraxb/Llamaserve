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
