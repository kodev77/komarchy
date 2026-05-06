#!/usr/bin/env bash
# updates: rollback workspace-default — remove the exec-once block.
set -euo pipefail

AUTOSTART="$HOME/.config/hypr/autostart.conf"

if [[ -f "$AUTOSTART" ]] && grep -q '^# --- komarchy workspace-default ---$' "$AUTOSTART"; then
  sed -i '/^# --- komarchy workspace-default ---$/,/^# --- end komarchy workspace-default ---$/d' "$AUTOSTART"
  sed -i -e :a -e '/^$/{$d;N;ba' -e '}' "$AUTOSTART"
  echo "removed workspace-default block"
else
  echo "workspace-default block not present"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
