#!/usr/bin/env bash
# updates: rollback bookmark manager alias and app-group files
set -euo pipefail

BASHRC="$HOME/.bashrc"
APP_GROUPS_DIR="$HOME/.config/omarchy/app-groups"

# remove bm function
if grep -q "^bm()" "$BASHRC"; then
  sed -i '/^bm()/,/^}/d' "$BASHRC"
  echo "  bm function: removed"
else
  echo "bm function not found, skipping"
fi

# remove bookmark files
if [[ -d "$APP_GROUPS_DIR" ]]; then
  rm -f "$APP_GROUPS_DIR"/*.md
  rmdir --ignore-fail-on-non-empty "$APP_GROUPS_DIR"
  echo "  app-groups: removed"
fi

echo ""
echo "open a new terminal to apply changes"
