#!/usr/bin/env bash
# waybar: waybar: add persistent workspaces 6-10
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

if grep -q '"6": \[\]' "$WAYBAR_CFG"; then
  echo "workspaces 6-10 already configured, skipping"
  exit 0
fi

echo "patching waybar workspaces..."
sed -i 's/"5": \[\]/"5": [],/' "$WAYBAR_CFG"
sed -i '/"5": \[\],/a\      "6": [],\n      "7": [],\n      "8": [],\n      "9": [],\n      "10": []' "$WAYBAR_CFG"
echo "waybar workspaces patched"
