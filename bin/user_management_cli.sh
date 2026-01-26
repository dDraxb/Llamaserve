#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/runtime/.user_venv"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "CLI venv not found at $VENV. Run ./bin/bootstrap_user_cli.sh first."
  exit 1
fi

exec "$VENV/bin/python" "$ROOT/bin/user_management_cli.py" "$@"
