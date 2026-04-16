#!/usr/bin/env bash
# neovim: rollback disable markdownlint
set -euo pipefail

CONFIG="$HOME/.markdownlint-cli2.jsonc"
PLUGIN="$HOME/.config/nvim/lua/plugins/disable-markdownlint.lua"
removed=false

if [[ -f "$CONFIG" ]] && grep -q 'komarchy: global markdownlint-cli2 config' "$CONFIG"; then
  rm -f "$CONFIG"
  echo "removed $CONFIG"
  removed=true
fi

if [[ -f "$PLUGIN" ]] && grep -q 'komarchy: disable markdownlint' "$PLUGIN"; then
  rm -f "$PLUGIN"
  echo "removed $PLUGIN"
  removed=true
fi

if ! $removed; then
  echo "nothing to roll back"
fi
