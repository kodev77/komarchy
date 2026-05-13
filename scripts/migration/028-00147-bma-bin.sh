#!/usr/bin/env bash
# bm-tool-alc: re-install bm launcher (alacritty-aware; replaces the ghostty-coupled version from group 019).
set -euo pipefail

SRC="$REPO_DIR/files/local/bin/bm"
DST="$HOME/.local/bin/bm"

mkdir -p "$(dirname "$DST")"
install -m 0755 "$SRC" "$DST"
echo "  bm launcher: $DST"
