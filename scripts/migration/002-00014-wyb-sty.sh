#!/usr/bin/env bash
# waybar: waybar: bar height, font size, bold styling
set -euo pipefail

# --- waybar/config.jsonc: bar height ---
WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"
if [[ -f "$WAYBAR_CFG" ]]; then
  echo "patching waybar bar height..."
  sed -i 's/"height": 26/"height": 32/' "$WAYBAR_CFG"
  echo "waybar bar height patched"
else
  echo "waybar config not found, skipping"
fi

# --- waybar/style.css: font size and bold ---
WAYBAR_CSS="$HOME/.config/waybar/style.css"
if [[ -f "$WAYBAR_CSS" ]]; then
  echo "patching waybar style..."

  # font size
  sed -i 's/font-size: 12px;/font-size: 11pt;/' "$WAYBAR_CSS"

  # workspace font-weight normal + bold rules
  if ! grep -q 'font-weight: normal' "$WAYBAR_CSS"; then
    sed -i '/#workspaces button {/,/}/{
      /min-width:/a\  font-weight: normal;
    }' "$WAYBAR_CSS"
  fi

  if ! grep -q 'button:not(.empty)' "$WAYBAR_CSS"; then
    sed -i '/#workspaces button.empty {/i\#workspaces button:not(.empty) {\n  font-weight: bold;\n}\n' "$WAYBAR_CSS"
  fi

  # clock font-weight bold
  if ! grep -q '#clock' "$WAYBAR_CSS" || ! sed -n '/#clock/,/}/p' "$WAYBAR_CSS" | grep -q 'font-weight: bold'; then
    sed -i '/#clock {/a\  font-weight: bold;' "$WAYBAR_CSS"
  fi

  echo "waybar style patched"
else
  echo "waybar style.css not found, skipping"
fi

echo ""
echo "restarting waybar..."
killall waybar 2>/dev/null; waybar &>/dev/null &disown
echo "waybar restarted"
