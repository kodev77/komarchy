#!/usr/bin/env bash
# hello: ghostty patch: font size 9 → 13
set -euo pipefail

GHOSTTY="$HOME/.config/ghostty/config"

if [[ -f "$GHOSTTY" ]]; then
  echo "patching ghostty font size..."
  sed -i 's/^font-size = 9$/font-size = 13/' "$GHOSTTY"
  echo "ghostty font size patched"
else
  echo "ghostty config not found, skipping"
fi
