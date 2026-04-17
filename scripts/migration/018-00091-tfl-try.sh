#!/usr/bin/env bash
# teams: start minimized to system tray, X button minimizes instead of quitting
set -euo pipefail

CONFIG_DIR="$HOME/.config/teams-for-linux"
CONFIG="$CONFIG_DIR/config.json"

if ! command -v teams-for-linux &>/dev/null; then
  echo "teams-for-linux not installed, skipping"
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo "jq required but not installed"
  exit 1
fi

mkdir -p "$CONFIG_DIR"

if [[ ! -f "$CONFIG" ]]; then
  echo '{}' > "$CONFIG"
fi

current_min=$(jq -r '.minimized // false' "$CONFIG")
current_close=$(jq -r '.closeAppOnCross // true' "$CONFIG")
if [[ "$current_min" == "true" && "$current_close" == "false" ]]; then
  echo "teams-for-linux already configured for tray minimize"
  exit 0
fi

# stop teams-for-linux first (it rewrites config.json on quit, clobbering changes)
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

echo "patching $CONFIG..."
tmp=$(mktemp)
jq '.minimized = true | .closeAppOnCross = false' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"
echo "teams-for-linux configured: starts minimized, X minimizes to tray"

echo ""
echo "launch teams-for-linux (run: teams-for-linux &) — it will start minimized to tray"
