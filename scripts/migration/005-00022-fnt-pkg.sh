#!/usr/bin/env bash
# berkeley: install Berkeley Mono font from local repo if available
set -euo pipefail

FONT_SRC="$HOME/repo/repository1-c/L3/fonts/Berkeley Mono TX-02/TX-02-ZN3QQVKK"
FONT_DST="$HOME/.local/share/fonts"

if ls "$FONT_DST"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono already installed"
  exit 0
fi

if [[ ! -d "$FONT_SRC" ]]; then
  echo "berkeley mono source repo not available, skipping"
  exit 2
fi

echo "installing berkeley mono..."
mkdir -p "$FONT_DST"
cp "$FONT_SRC"/*.ttf "$FONT_DST/"
fc-cache -f
echo "berkeley mono installed"
