#!/usr/bin/env bash
# berkeley: fontconfig: swap monospace default to Berkeley Mono
set -euo pipefail

FONTS_CONF="$HOME/.config/fontconfig/fonts.conf"

if [[ ! -f "$FONTS_CONF" ]]; then
  echo "fonts.conf not found, skipping"
  exit 0
fi

if ! ls "$HOME/.local/share/fonts"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 2
fi

echo "patching fontconfig..."
sed -i 's|<string>JetBrainsMono Nerd Font</string>|<string>Berkeley Mono</string>|' "$FONTS_CONF"
fc-cache -f
echo "fontconfig patched"
