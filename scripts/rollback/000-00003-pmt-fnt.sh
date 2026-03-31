#!/usr/bin/env bash
# hello: ghostty rollback: font size 13 → 9
set -euo pipefail

GHOSTTY="$HOME/.config/ghostty/config"

if [[ -f "$GHOSTTY" ]]; then
  echo "reverting ghostty font size..."
  sed -i 's/^font-size = 13$/font-size = 9/' "$GHOSTTY"
  echo "ghostty font size reverted"
else
  echo "ghostty config not found, skipping"
fi
