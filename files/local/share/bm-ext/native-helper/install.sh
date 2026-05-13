#!/usr/bin/env bash
# install.sh — render manifest.json.in and place it where chromium will find it.
#
# Usage:
#   ./install.sh <EXTENSION_ID>
#
# EXTENSION_ID is the 32-char id chromium assigned to your unpacked extension.
# Find it at chrome://extensions/ after loading the unpacked dist/ dir.
#
# Installs to:
#   ~/.config/chromium/NativeMessagingHosts/com.ko.bm_store.json
#
# Idempotent — re-running with a different EXTENSION_ID just rewrites the file.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <EXTENSION_ID>" >&2
  exit 1
fi

EXT_ID="$1"

# Sanity check: chromium IDs are 32 lowercase letters (a-p).
if [[ ! "$EXT_ID" =~ ^[a-p]{32}$ ]]; then
  echo "warning: '$EXT_ID' doesn't look like a chromium extension id (32 chars a-p)" >&2
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_PATH="$HELPER_DIR/bm-store.py"
TEMPLATE="$HELPER_DIR/manifest.json.in"

if [[ ! -x "$HELPER_PATH" ]]; then
  chmod +x "$HELPER_PATH"
fi

NM_DIR="$HOME/.config/chromium/NativeMessagingHosts"
NM_FILE="$NM_DIR/com.ko.bm_store.json"
mkdir -p "$NM_DIR"

sed \
  -e "s|__HELPER_PATH__|$HELPER_PATH|g" \
  -e "s|__EXTENSION_ID__|$EXT_ID|g" \
  "$TEMPLATE" > "$NM_FILE"

echo "installed: $NM_FILE"
echo "  helper:    $HELPER_PATH"
echo "  extension: $EXT_ID"
