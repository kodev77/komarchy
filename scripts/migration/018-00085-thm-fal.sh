#!/usr/bin/env bash
# updates: install retro-fallout theme (without activating)
set -euo pipefail

THEME_DIR="$HOME/.config/omarchy/themes/retro-fallout"
REPO_URL="https://github.com/zdravkodanailov7/omarchy-retro-fallout-theme.git"

if [[ -d "$THEME_DIR" ]]; then
  echo "retro-fallout theme already installed"
  exit 0
fi

mkdir -p "$(dirname "$THEME_DIR")"
git clone "$REPO_URL" "$THEME_DIR"
echo "retro-fallout theme installed (Super+Ctrl+Shift+Space to switch)"
