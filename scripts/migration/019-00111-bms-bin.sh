#!/usr/bin/env bash
# bm-tool: install bm launcher and ghostty config.
# saved-tabs.json is no longer seeded — bm reads/writes it directly
# from the repo (BM_SAVED_TABS in the launcher) so cross-machine sync
# happens through git pull/push instead of a per-host copy.
set -euo pipefail

SRC_BIN="$REPO_DIR/files/local/bin/bm"
SRC_GHOSTTY="$REPO_DIR/files/config/ghostty/bm.conf"

DST_BIN="$HOME/.local/bin/bm"
DST_GHOSTTY="$HOME/.config/ghostty/bm.conf"

mkdir -p "$(dirname "$DST_BIN")" "$(dirname "$DST_GHOSTTY")"

install -m 0755 "$SRC_BIN" "$DST_BIN"
echo "  bm launcher: $DST_BIN"

install -m 0644 "$SRC_GHOSTTY" "$DST_GHOSTTY"
echo "  ghostty bm.conf: $DST_GHOSTTY"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "warning: $HOME/.local/bin not on PATH — open a new shell" ;;
esac
