#!/usr/bin/env bash
# updates: rollback retro-fallout theme install
set -euo pipefail

THEME_DIR="$HOME/.config/omarchy/themes/retro-fallout"
if [[ ! -d "$THEME_DIR" ]]; then
  echo "retro-fallout theme not installed, skipping"
  exit 0
fi

omarchy-theme-remove retro-fallout
echo "retro-fallout theme removed"
