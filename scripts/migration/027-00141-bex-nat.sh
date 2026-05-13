#!/usr/bin/env bash
# bm-chromium: install native messaging host manifest for the bm extension
set -euo pipefail

# Extension ID derived from the unpacked path. Stable across machines
# as long as komarchy lives under the same $HOME-relative path.
EXT_ID="bflldnjkoaobgnmmpbldagkmnipanggm"

NAT_DIR="$REPO_DIR/files/local/share/bm-ext/native-helper"
PREFS="$HOME/.config/chromium/Default/Preferences"

if [[ ! -d "$NAT_DIR" ]]; then
  echo "native-helper source not found at $NAT_DIR, skipping"
  exit 2
fi

# The NM host manifest's allowed_origins points at the extension ID, so
# chromium needs to know about the extension before this step makes
# sense. Detect by grepping the profile's Preferences for the ID.
if [[ ! -f "$PREFS" ]] || ! grep -q "$EXT_ID" "$PREFS" 2>/dev/null; then
  echo "extension not yet loaded in chromium (id $EXT_ID not in $PREFS)"
  echo "load $REPO_DIR/files/local/share/bm-ext/extension/dist/ as unpacked"
  echo "at chrome://extensions, then re-run migrate.sh"
  exit 2
fi

bash "$NAT_DIR/install.sh" "$EXT_ID"
