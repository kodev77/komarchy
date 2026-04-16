#!/usr/bin/env bash
# updates: install omarchy95 theme (without activating)
set -euo pipefail

THEME_DIR="$HOME/.config/omarchy/themes/omarchy95"
REPO_URL="https://github.com/atif-1402/omarchy-omarchy95-theme.git"

if [[ -d "$THEME_DIR" ]]; then
  echo "omarchy95 theme already installed"
  exit 0
fi

mkdir -p "$(dirname "$THEME_DIR")"
git clone "$REPO_URL" "$THEME_DIR"
echo "omarchy95 theme installed (Super+Ctrl+Shift+Space to switch)"
