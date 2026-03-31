#!/usr/bin/env bash
# dataverse: rollback python venv with requests and tabulate for the dvquery dataverse cli tool
set -euo pipefail

VENV_DIR="$HOME/.local/share/dvquery-venv"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "dvquery venv not found, skipping"
  exit 0
fi

echo "removing dvquery venv..."
rm -rf "$VENV_DIR"
echo "dvquery venv removed"
