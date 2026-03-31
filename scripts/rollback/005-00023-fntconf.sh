#!/usr/bin/env bash
# berkeley: rollback fontconfig monospace to JetBrainsMono
set -euo pipefail

FONTS_CONF="$HOME/.config/fontconfig/fonts.conf"

if [[ ! -f "$FONTS_CONF" ]]; then
  echo "fonts.conf not found, skipping"
  exit 0
fi

echo "reverting fontconfig..."
sed -i 's|<string>Berkeley Mono</string>|<string>JetBrainsMono Nerd Font</string>|' "$FONTS_CONF"
fc-cache -f
echo "fontconfig reverted"
