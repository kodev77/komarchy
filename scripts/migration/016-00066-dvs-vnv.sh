#!/usr/bin/env bash
# dataverse: python venv with requests and tabulate for the dvquery dataverse cli tool
set -euo pipefail

VENV_DIR="$HOME/.local/share/dvquery-venv"

if [[ -d "$VENV_DIR" ]] && "$VENV_DIR/bin/python" -c "import requests, tabulate" 2>/dev/null; then
  echo "dvquery venv already exists with correct packages — skipping"
  exit 0
fi

echo "Creating dvquery virtual environment at $VENV_DIR..."
python3 -m venv "$VENV_DIR"

echo "Installing packages..."
"$VENV_DIR/bin/pip" install --quiet requests tabulate

echo "Verifying..."
"$VENV_DIR/bin/python" -c "import requests, tabulate; print('  requests + tabulate: OK')"
