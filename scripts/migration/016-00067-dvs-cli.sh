#!/usr/bin/env bash
# dataverse: custom cli tool for querying dataverse/dynamics 365 environments from the terminal
set -euo pipefail

mkdir -p "$HOME/.local/bin"

echo "Copying dvquery..."
cp "$REPO_DIR/files/local/bin/dvquery" "$HOME/.local/bin/dvquery"
chmod +x "$HOME/.local/bin/dvquery"

echo "  dvquery: OK"
