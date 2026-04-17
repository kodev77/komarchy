#!/usr/bin/env bash
# teams: rollback tray re-enable + expander restore
set -euo pipefail

TFL_CONFIG="$HOME/.config/teams-for-linux/config.json"
WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ -f "$TFL_CONFIG" ]] && command -v jq &>/dev/null; then
  current=$(jq -r '.trayIconEnabled // true' "$TFL_CONFIG")
  if [[ "$current" == "true" ]]; then
    tmp=$(mktemp)
    jq '.trayIconEnabled = false' "$TFL_CONFIG" > "$tmp"
    mv "$tmp" "$TFL_CONFIG"
    echo "  teams-for-linux: trayIconEnabled = false"
  fi
fi

if [[ -f "$WAYBAR_CONFIG" ]]; then
  if grep -qE '^    "group/tray-expander",$' "$WAYBAR_CONFIG"; then
    sed -i 's|^    "group/tray-expander",$|    "tray",|' "$WAYBAR_CONFIG"
    echo "  waybar: modules-right reverted to plain tray"
    pkill -SIGUSR2 waybar 2>/dev/null || true
  fi
fi

echo ""
echo "restart teams-for-linux to apply tray-disable immediately if desired."
