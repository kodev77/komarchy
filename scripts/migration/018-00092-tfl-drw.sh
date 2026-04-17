#!/usr/bin/env bash
# teams: re-enable native tray icon and tuck waybar tray back into expander drawer
set -euo pipefail

TFL_CONFIG="$HOME/.config/teams-for-linux/config.json"
WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"

if ! command -v teams-for-linux &>/dev/null; then
  echo "teams-for-linux not installed, skipping"
  exit 2
fi
if ! command -v jq &>/dev/null; then
  echo "jq required but not installed"
  exit 1
fi

# --- 1. stop teams-for-linux first (it rewrites config.json on quit, clobbering changes) ---
if pgrep -x teams-for-linux >/dev/null 2>&1; then
  echo "  stopping teams-for-linux to prevent config clobbering..."
  pkill -f teams-for-linux 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x teams-for-linux >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f teams-for-linux 2>/dev/null || true
  sleep 1
fi

# --- 2. enable teams-for-linux native SNI tray icon ---
if [[ -f "$TFL_CONFIG" ]]; then
  current=$(jq -r '.trayIconEnabled // true' "$TFL_CONFIG")
  if [[ "$current" != "true" ]]; then
    tmp=$(mktemp)
    jq '.trayIconEnabled = true' "$TFL_CONFIG" > "$tmp"
    mv "$tmp" "$TFL_CONFIG"
    echo "  teams-for-linux: trayIconEnabled = true"
  else
    echo "  teams-for-linux: tray already enabled"
  fi
else
  echo "  teams-for-linux config not found, skipping config change"
fi

# --- 3. restore waybar expander drawer (undo 018-00082 for modules-right) ---
if [[ -f "$WAYBAR_CONFIG" ]]; then
  if grep -qE '^    "tray",$' "$WAYBAR_CONFIG"; then
    sed -i 's|^    "tray",$|    "group/tray-expander",|' "$WAYBAR_CONFIG"
    echo "  waybar: modules-right now uses group/tray-expander"
    pkill -SIGUSR2 waybar 2>/dev/null || true
  else
    echo "  waybar: modules-right already uses group/tray-expander"
  fi
else
  echo "  waybar config not found, skipping"
fi

echo ""
echo "launch teams-for-linux to see its native tray icon (run: teams-for-linux &)"
