#!/usr/bin/env bash
# terminal: rollback ghostty config
set -euo pipefail

GHOSTTY="$HOME/.config/ghostty/config"

if [[ ! -f "$GHOSTTY" ]]; then
  echo "ghostty config not found, skipping"
  exit 0
fi

echo "reverting ghostty config..."

# cursor-style-blink true → false
sed -i 's/^cursor-style-blink = true$/cursor-style-blink = false/' "$GHOSTTY"

# remove cursor-color and theme block at end
sed -i '/^# Dynamic theme colors (loaded last so user settings above take priority)$/d' "$GHOSTTY"
sed -i '/^config-file = ?"~\/.config\/omarchy\/current\/theme\/ghostty.conf"$/d' "$GHOSTTY"
sed -i '/^# Override theme cursor color$/d' "$GHOSTTY"
sed -i '/^cursor-color = #D7C995$/d' "$GHOSTTY"

# restore theme config-file at top if missing
if ! grep -q 'config-file.*ghostty.conf' "$GHOSTTY"; then
  sed -i '1i\# Dynamic theme colors\nconfig-file = ?"~/.config/omarchy/current/theme/ghostty.conf"\n' "$GHOSTTY"
fi

echo "ghostty config reverted"
