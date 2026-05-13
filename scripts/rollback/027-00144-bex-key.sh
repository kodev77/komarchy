#!/usr/bin/env bash
# bm-chromium: unbind chromium keyboard shortcuts for the bm extension
set -euo pipefail

EXT_ID="bflldnjkoaobgnmmpbldagkmnipanggm"
SCRIPT="$REPO_DIR/files/local/share/bm-ext/native-helper/unbind-shortcuts.py"
PREFS="$HOME/.config/chromium/Default/Preferences"

if [[ ! -x "$SCRIPT" ]]; then
  echo "unbind-shortcuts.py not found at $SCRIPT, skipping"
  exit 0
fi

if [[ ! -f "$PREFS" ]]; then
  echo "chromium profile not found, nothing to roll back"
  exit 0
fi

if pgrep -x chromium >/dev/null; then
  echo "chromium is running — close it first, then re-run rollback"
  exit 1
fi

python3 "$SCRIPT" "$EXT_ID"
