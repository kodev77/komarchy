#!/usr/bin/env bash
# berkeley: remove Berkeley Mono font
set -euo pipefail

FONT_DST="$HOME/.local/share/fonts"

if ! ls "$FONT_DST"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 0
fi

echo "removing berkeley mono..."
rm -f "$FONT_DST"/BerkeleyMono*.ttf
fc-cache -f
echo "berkeley mono removed"

echo ""
echo "close all open terminals and open a new terminal to see changes"
