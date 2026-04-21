#!/usr/bin/env bash
# bm-tool: rollback hyprland bm patches
set -euo pipefail

BINDINGS="$HOME/.config/hypr/bindings.conf"
LOOKFEEL="$HOME/.config/hypr/looknfeel.conf"

strip_block() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" ]] || { echo "  $(basename "$file"): not found, skipping"; return 0; }
  if ! grep -qF "$begin" "$file"; then
    echo "  $(basename "$file"): bm block not present, skipping"
    return 0
  fi
  sed -i "/$begin/,/$end/d" "$file"
  echo "  $(basename "$file"): bm block removed"
}

strip_block "$BINDINGS" "# --- BEGIN ko komarchy bm-tool bindings ---" "# --- END ko komarchy bm-tool bindings ---"
strip_block "$LOOKFEEL" "# --- BEGIN ko komarchy bm-tool windowrules ---" "# --- END ko komarchy bm-tool windowrules ---"

echo ""
echo "reload hyprland to apply: hyprctl reload"
