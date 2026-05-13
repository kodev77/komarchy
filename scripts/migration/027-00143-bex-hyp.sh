#!/usr/bin/env bash
# bm-chromium: repoint Super+Alt+H from `bm focus` (python TUI) to `bm-ext-focus`
set -euo pipefail

BINDINGS="$HOME/.config/hypr/bindings.conf"

if [[ ! -f "$BINDINGS" ]]; then
  echo "hyprland bindings.conf not found, skipping"
  exit 2
fi

# Idempotent: detect the original `bm focus` exec line and rewrite it.
# Match is intentionally specific — only when the H row still points at
# the python TUI launcher — so re-runs are no-ops once patched.
if grep -q '\$HOME/.local/bin/bm focus' "$BINDINGS"; then
  sed -i 's|\$HOME/\.local/bin/bm focus|$HOME/.local/bin/bm-ext-focus|' "$BINDINGS"
  echo "patched bindings.conf: Super+Alt+H -> bm-ext-focus"
else
  echo "bindings.conf already patched (no \`bm focus\` line found)"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
