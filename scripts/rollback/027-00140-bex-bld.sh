#!/usr/bin/env bash
# bm-chromium: rollback extension build — drop dist/ and node_modules/
set -euo pipefail

EXT_DIR="$REPO_DIR/files/local/share/bm-ext/extension"

if [[ ! -d "$EXT_DIR" ]]; then
  echo "extension source not found, nothing to roll back"
  exit 0
fi

cd "$EXT_DIR"
rm -rf dist node_modules
echo "removed dist/ and node_modules/ in $EXT_DIR"
