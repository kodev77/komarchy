#!/usr/bin/env bash
# hyprland: rollback hyprland resize keybindings
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/bindings.conf" ]]; then
  echo "bindings.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko komarchy keybinds ---' "$HYPR/bindings.conf"; then
  echo "removing keybinds..."
  sed -i '/# --- BEGIN ko komarchy keybinds ---/,/# --- END ko komarchy keybinds ---/d' "$HYPR/bindings.conf"
  echo "bindings.conf reverted"
else
  echo "keybinds not found, skipping"
fi
