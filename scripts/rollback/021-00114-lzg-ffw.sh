#!/usr/bin/env bash
# updates: rollback lazygit autoForwardBranches: restore the default
# (onlyMainBranches) by removing the explicit override.
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"

if [[ ! -f "$CONFIG" ]]; then
  echo "lazygit config not found, skipping"
  exit 0
fi

echo "rolling back lazygit autoForwardBranches..."

sed -i '/^  autoForwardBranches: none$/d' "$CONFIG"

echo "autoForwardBranches removed (back to default onlyMainBranches)"
