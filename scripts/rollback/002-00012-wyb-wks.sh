#!/usr/bin/env bash
# waybar: rollback waybar workspaces 6-10
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

if ! grep -q '"6": \[\]' "$WAYBAR_CFG"; then
  echo "workspaces 6-10 not found, skipping"
  exit 0
fi

echo "reverting waybar workspaces..."
sed -i '/"6": \[\]/d; /"7": \[\]/d; /"8": \[\]/d; /"9": \[\]/d; /"10": \[\]/d' "$WAYBAR_CFG"
# remove trailing comma from "5" line
sed -i 's/"5": \[\],/"5": []/' "$WAYBAR_CFG"
echo "waybar workspaces reverted"

echo ""
echo "restarting waybar..."
killall waybar 2>/dev/null; waybar &>/dev/null &disown
echo "waybar restarted"
