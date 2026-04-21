#!/usr/bin/env bash
# bm-tool: install bm launcher, ghostty config, and seed saved-tabs.json
set -euo pipefail

SRC_BIN="$REPO_DIR/files/local/bin/bm"
SRC_GHOSTTY="$REPO_DIR/files/config/ghostty/bm.conf"
SRC_SAVED="$REPO_DIR/files/config/omarchy/bm/saved-tabs.json"

DST_BIN="$HOME/.local/bin/bm"
DST_GHOSTTY="$HOME/.config/ghostty/bm.conf"
DST_SAVED="$HOME/.config/omarchy/bm/saved-tabs.json"

mkdir -p "$(dirname "$DST_BIN")" "$(dirname "$DST_GHOSTTY")" "$(dirname "$DST_SAVED")"

install -m 0755 "$SRC_BIN" "$DST_BIN"
echo "  bm launcher: $DST_BIN"

install -m 0644 "$SRC_GHOSTTY" "$DST_GHOSTTY"
echo "  ghostty bm.conf: $DST_GHOSTTY"

# Don't overwrite an existing saved-tabs.json — the user's data wins.
if [[ -f "$DST_SAVED" ]]; then
  echo "  saved-tabs.json: already present (preserved)"
else
  install -m 0644 "$SRC_SAVED" "$DST_SAVED"
  echo "  saved-tabs.json: seeded at $DST_SAVED"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "warning: $HOME/.local/bin not on PATH — open a new shell" ;;
esac
