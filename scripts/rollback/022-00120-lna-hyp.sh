#!/usr/bin/env bash
# retro: rollback linapple hyprland windowrule patch
set -euo pipefail

LOOKFEEL="$HOME/.config/hypr/looknfeel.conf"

LNA_RULE_BEGIN="# --- BEGIN ko komarchy linapple windowrules ---"
LNA_RULE_END="# --- END ko komarchy linapple windowrules ---"

strip_block() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" ]] || { echo "  $(basename "$file"): not found, skipping"; return 0; }
  if ! grep -qF "$begin" "$file"; then
    echo "  $(basename "$file"): linapple block not present, skipping"
    return 0
  fi
  sed -i "/$begin/,/$end/d" "$file"
  echo "  $(basename "$file"): linapple block removed"
}

strip_block "$LOOKFEEL" "$LNA_RULE_BEGIN" "$LNA_RULE_END"

echo ""
echo "reload hyprland to apply: hyprctl reload"
