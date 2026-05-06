#!/usr/bin/env bash
# updates: rollback rog-quiet-boot — remove autostart block and helper script.
set -euo pipefail

SCRIPT="$HOME/.local/bin/komarchy-rog-quiet-boot"
AUTOSTART="$HOME/.config/hypr/autostart.conf"

if [[ -f "$AUTOSTART" ]] && grep -q '^# --- komarchy rog-quiet-boot ---$' "$AUTOSTART"; then
  sed -i '/^# --- komarchy rog-quiet-boot ---$/,/^# --- end komarchy rog-quiet-boot ---$/d' "$AUTOSTART"
  # collapse any trailing blank line we left behind
  sed -i -e :a -e '/^$/{$d;N;ba' -e '}' "$AUTOSTART"
  echo "removed autostart block"
fi

if [[ -f "$SCRIPT" ]]; then
  rm -f "$SCRIPT"
  echo "removed $SCRIPT"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
