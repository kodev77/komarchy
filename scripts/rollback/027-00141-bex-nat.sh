#!/usr/bin/env bash
# bm-chromium: rollback NM host install — remove chromium's host manifest
set -euo pipefail

NM_FILE="$HOME/.config/chromium/NativeMessagingHosts/com.ko.bm_store.json"

if [[ ! -f "$NM_FILE" ]]; then
  echo "NM host manifest not present, nothing to roll back"
  exit 0
fi

rm "$NM_FILE"
echo "removed $NM_FILE"
