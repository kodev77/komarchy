#!/usr/bin/env bash
# teams: rollback tray-minimize config
set -euo pipefail

CONFIG="$HOME/.config/teams-for-linux/config.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "no teams-for-linux config, skipping"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "jq required for rollback but not installed"
  exit 1
fi

echo "reverting $CONFIG..."
tmp=$(mktemp)
jq 'del(.minimized) | del(.closeAppOnCross)' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"

if [[ "$(jq -r 'keys | length' "$CONFIG")" == "0" ]]; then
  rm -f "$CONFIG"
  echo "removed now-empty $CONFIG"
else
  echo "removed minimized/closeAppOnCross keys"
fi
