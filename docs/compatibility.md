# Compatibility Matrix

Llamaserve currently targets a stable runtime over broad version coverage.

## Supported runtime

- OS: macOS, Linux
- Python: 3.11, 3.12
- `llama-cpp-python`: 0.2.90 and 0.3.16 (tracked in CI matrix)

## Windows policy

- Supported path: WSL2 (Ubuntu)
- Not supported: native Git Bash/MSYS/Cygwin execution for install/runtime scripts

## Why Python 3.11/3.12 only

- Recent Python 3.13/3.14 environments have shown unstable behavior with local `llama-cpp-python` builds on some systems.
- The installer now validates Python and fails fast outside 3.11/3.12 to prevent hard-to-debug runtime crashes.

## Upgrade policy

1. Weekly compatibility workflow runs a matrix across OS/Python/`llama-cpp-python`.
2. If a newer version is consistently green, we expand support and update this file.
3. If regressions appear, we pin to the last known-good combo and document it in `CHANGELOG.md`.
