#!/usr/bin/env bash
# dataverse: rollback custom cli tool for querying dataverse/dynamics 365 environments from the terminal
set -euo pipefail

if [[ ! -f "$HOME/.local/bin/dvquery" ]]; then
  echo "dvquery not found, skipping"
  exit 0
fi

echo "removing dvquery..."
rm "$HOME/.local/bin/dvquery"
echo "dvquery removed"
