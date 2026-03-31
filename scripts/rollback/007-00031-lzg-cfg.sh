#!/usr/bin/env bash
# lazygit: rollback lazygit config: custom log format with short hash, dim message, and auto decorations
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"

if [[ ! -f "$CONFIG" ]]; then
  echo "lazygit config not found, skipping"
  exit 0
fi

echo "removing lazygit config..."
rm "$CONFIG"
echo "lazygit config removed"

echo ""
echo "open a new terminal to apply changes"
