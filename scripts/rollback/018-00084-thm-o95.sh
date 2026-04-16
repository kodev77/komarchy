#!/usr/bin/env bash
# updates: rollback omarchy95 theme install
set -euo pipefail

THEME_DIR="$HOME/.config/omarchy/themes/omarchy95"
if [[ ! -d "$THEME_DIR" ]]; then
  echo "omarchy95 theme not installed, skipping"
  exit 0
fi

omarchy-theme-remove omarchy95
echo "omarchy95 theme removed"
