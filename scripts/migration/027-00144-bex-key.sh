#!/usr/bin/env bash
# bm-chromium: bind chromium keyboard shortcuts via bind-shortcuts.py
#
# Writes Preferences directly to register Alt+Shift+B (toggle side panel)
# and Alt+Shift+S (save current tab). Chromium silently drops some
# `suggested_key` entries on install, so this fills the gap so a fresh
# machine doesn't require manual binding at chrome://extensions/shortcuts.

set -euo pipefail

EXT_ID="bflldnjkoaobgnmmpbldagkmnipanggm"
SCRIPT="$REPO_DIR/files/local/share/bm-ext/native-helper/bind-shortcuts.py"
PREFS="$HOME/.config/chromium/Default/Preferences"

if [[ ! -x "$SCRIPT" ]]; then
  echo "bind-shortcuts.py not found at $SCRIPT, skipping"
  exit 2
fi

if [[ ! -f "$PREFS" ]]; then
  echo "chromium profile not found, skipping (start chromium once to create it)"
  exit 2
fi

if pgrep -x chromium >/dev/null; then
  echo "chromium is running — close all chromium windows, then re-run migrate.sh"
  echo "(Preferences edits are clobbered when chromium quits, so the bind has to happen while chromium is closed)"
  exit 2
fi

python3 "$SCRIPT" "$EXT_ID"
