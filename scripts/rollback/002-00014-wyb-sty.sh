#!/usr/bin/env bash
# waybar: rollback waybar bar height, font size, bold styling
set -euo pipefail

# --- waybar/config.jsonc: bar height ---
WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"
if [[ -f "$WAYBAR_CFG" ]]; then
  echo "reverting waybar bar height..."
  sed -i 's/"height": 32/"height": 26/' "$WAYBAR_CFG"
  echo "waybar bar height reverted"
fi

# --- waybar/style.css: font size and bold ---
WAYBAR_CSS="$HOME/.config/waybar/style.css"
if [[ -f "$WAYBAR_CSS" ]]; then
  echo "reverting waybar style..."

  # font size
  sed -i 's/font-size: 11pt;/font-size: 12px;/' "$WAYBAR_CSS"

  # remove workspace font-weight normal
  sed -i '/^  font-weight: normal;$/d' "$WAYBAR_CSS"

  # remove button:not(.empty) block
  sed -i '/#workspaces button:not(.empty) {/,/^}/d' "$WAYBAR_CSS"

  # remove clock font-weight bold
  sed -i '/#clock {/,/}/{/^  font-weight: bold;$/d}' "$WAYBAR_CSS"

  echo "waybar style reverted"
fi
