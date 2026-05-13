#!/usr/bin/env bash
# bm-chromium: revert Super+Alt+H Hyprland binding to `bm focus`
set -euo pipefail

BINDINGS="$HOME/.config/hypr/bindings.conf"

if [[ ! -f "$BINDINGS" ]]; then
  echo "hyprland bindings.conf not found, nothing to roll back"
  exit 0
fi

if grep -q '\$HOME/.local/bin/bm-ext-focus' "$BINDINGS"; then
  sed -i 's|\$HOME/\.local/bin/bm-ext-focus|$HOME/.local/bin/bm focus|' "$BINDINGS"
  echo "reverted bindings.conf: Super+Alt+H -> bm focus"
else
  echo "bindings.conf doesn't reference bm-ext-focus, nothing to roll back"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
