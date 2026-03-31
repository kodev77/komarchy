#!/usr/bin/env bash
# dataverse: rollback vimscript db adapter routing queries through dvquery cli
set -euo pipefail

ADAPTER="$HOME/.config/nvim/autoload/db/adapter/dataverse.vim"

if [[ ! -f "$ADAPTER" ]]; then
  echo "dataverse adapter not found, skipping"
  exit 0
fi

echo "removing dataverse adapter..."
rm "$ADAPTER"
echo "dataverse adapter removed"

echo ""
echo "restart nvim to apply changes"
