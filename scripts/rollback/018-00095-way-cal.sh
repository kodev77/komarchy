#!/usr/bin/env bash
# updates: rollback waycal swap — restore lvsk-calendar clock right-click
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

# --- 1. restore waybar clock on-click-right to lvsk-calendar ---
if [[ -f "$WAYBAR_CFG" ]] && grep -q '"on-click-right": "waycal"' "$WAYBAR_CFG"; then
  TMP_REPL=$(mktemp)
  cat > "$TMP_REPL" <<'EOF'
    "on-click-right": "bash -c 'hyprctl keyword windowrule \"float on, match:title ^lvsk-calendar$\" && hyprctl keyword windowrule \"size 1200 700, match:title ^lvsk-calendar$\" && hyprctl keyword windowrule \"center on, match:title ^lvsk-calendar$\" && ghostty --title=lvsk-calendar --quit-after-last-window-closed -e /usr/bin/lvsk-calendar'"
EOF

  awk -v rf="$TMP_REPL" '
    /"on-click-right": "waycal"/ {
      while ((getline line < rf) > 0) print line
      close(rf)
      next
    }
    { print }
  ' "$WAYBAR_CFG" > "$WAYBAR_CFG.tmp" && mv "$WAYBAR_CFG.tmp" "$WAYBAR_CFG"
  rm -f "$TMP_REPL"
  echo "  waybar: clock right-click restored to lvsk-calendar"
else
  echo "  waybar clock already reverted (or no waycal entry)"
fi

# --- 2. uninstall waycal ---
if pacman -Qi waycal &>/dev/null; then
  echo "  removing waycal..."
  sudo pacman -Rns --noconfirm waycal
fi

pkill -SIGUSR2 waybar 2>/dev/null || true

echo ""
echo "lvsk-calendar restored as clock right-click action."
