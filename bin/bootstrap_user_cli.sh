#!/usr/bin/env bash
set -euo pipefail

# Bootstraps a venv with deps for user management CLI
# Usage:
#   ./bin/bootstrap_user_cli.sh
#   ./bin/bootstrap_user_cli.sh -- run ./bin/user_management_cli.py list-users
#   ./bin/bootstrap_user_cli.sh --python python3.11

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${VENV_DIR:-$ROOT/runtime/.user_venv}"
PY="${PYTHON_BIN:-${1:-python3}}"

if [[ "${1:-}" == "--python" ]]; then
  shift
  PY="$1"
  shift || true
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "Creating venv at $VENV_DIR using $PY ..."
  "$PY" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "Installing CLI deps..."
pip install --upgrade pip >/dev/null
pip install python-dotenv psycopg2-binary >/dev/null

echo "Venv ready at $VENV_DIR"
if [[ $# -gt 0 ]]; then
  exec "$@"
else
  echo "To run the user management CLI:"
  echo "  ./bin/user_management_cli.sh list-users"
fi
