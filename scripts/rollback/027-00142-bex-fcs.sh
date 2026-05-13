#!/usr/bin/env bash
# bm-chromium: rollback bm-ext-focus script install
set -euo pipefail

DST="$HOME/.local/bin/bm-ext-focus"

if [[ ! -f "$DST" ]]; then
  echo "bm-ext-focus not installed, nothing to roll back"
  exit 0
fi

rm "$DST"
echo "removed $DST"
