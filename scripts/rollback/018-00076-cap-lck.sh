#!/usr/bin/env bash
# updates: rollback caps lock to normal behavior (restore compose:caps remap)
set -euo pipefail

CONFIG="$HOME/.config/hypr/input.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "hyprland input.conf not found, skipping"
  exit 0
fi

if grep -q '^  kb_options = compose:caps' "$CONFIG"; then
  echo "compose:caps already set, skipping"
  exit 0
fi

echo "restoring compose:caps remap..."
sed -i 's|^  kb_options =.*|  kb_options = compose:caps # ,grp:alts_toggle|' "$CONFIG"
echo "compose:caps restored"
