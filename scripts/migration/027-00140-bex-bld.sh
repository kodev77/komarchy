#!/usr/bin/env bash
# bm-chromium: install dependencies and build the side-panel extension
set -euo pipefail

EXT_DIR="$REPO_DIR/files/local/share/bm-ext/extension"

if [[ ! -d "$EXT_DIR" ]]; then
  echo "extension source not found at $EXT_DIR, skipping"
  exit 2
fi

if ! command -v npm &>/dev/null; then
  echo "npm not found in PATH — install node first (mise or pacman -S nodejs)"
  exit 1
fi

cd "$EXT_DIR"

echo "installing extension deps..."
# npm ci uses package-lock.json when present and is reproducible; falls
# back to npm install on first build before a lock file exists.
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

echo "building extension..."
npm run build

echo ""
echo "extension built at:"
echo "  $EXT_DIR/dist"
echo ""
echo "next step: load it as an unpacked extension in chromium"
echo "  1. open chrome://extensions"
echo "  2. toggle Developer mode (top right)"
echo "  3. click 'Load unpacked' and select the dist/ dir above"
echo "  4. re-run migrate.sh — remaining bm-chromium steps need chromium to know about the extension"
