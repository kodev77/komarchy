#!/usr/bin/env bash
# neovim: rollback 6502 assembly (ACME) syntax plugin
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/acme-6502.lua"

if [[ -f "$PLUGIN" ]] && grep -q 'komarchy: 6502 assembly' "$PLUGIN"; then
  rm -f "$PLUGIN"
  echo "removed $PLUGIN"
else
  echo "nothing to roll back"
fi
