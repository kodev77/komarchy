#!/usr/bin/env bash
# updates: restore caps lock to normal behavior (remove compose:caps remap)
set -euo pipefail

CONFIG="$HOME/.config/hypr/input.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "hyprland input.conf not found, skipping"
  exit 2
fi

if ! grep -q '^  kb_options = compose:caps' "$CONFIG"; then
  echo "caps lock already normal, skipping"
  exit 0
fi

echo "restoring caps lock to normal behavior..."
sed -i 's|^  kb_options = compose:caps|  kb_options =|' "$CONFIG"
echo "caps lock restored"
