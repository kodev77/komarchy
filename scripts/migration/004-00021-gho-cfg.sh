#!/usr/bin/env bash
# terminal: ghostty patches: blinking cursor, custom cursor color, theme load order
set -euo pipefail

GHOSTTY="$HOME/.config/ghostty/config"

if [[ ! -f "$GHOSTTY" ]]; then
  echo "ghostty config not found, skipping"
  exit 0
fi

echo "patching ghostty config..."

# cursor-style-blink false → true
sed -i 's/^cursor-style-blink = false$/cursor-style-blink = true/' "$GHOSTTY"

# move theme config-file to end (remove from top, append at bottom)
if head -3 "$GHOSTTY" | grep -q 'config-file.*ghostty.conf'; then
  sed -i '/^# Dynamic theme colors$/d; /^config-file = ?"~\/.config\/omarchy\/current\/theme\/ghostty.conf"$/d' "$GHOSTTY"
  # remove leading blank lines left behind
  sed -i '1{/^$/d}' "$GHOSTTY"
fi

# add cursor-color and theme at end if not already there
if ! grep -q 'cursor-color' "$GHOSTTY"; then
  cat >> "$GHOSTTY" << 'EOF'

# Dynamic theme colors (loaded last so user settings above take priority)
config-file = ?"~/.config/omarchy/current/theme/ghostty.conf"

# Override theme cursor color
cursor-color = #D7C995
EOF
fi

echo "ghostty config patched"
echo ""
echo "close all open terminals and open a new terminal to see changes"
