#!/usr/bin/env bash
# bm-tool-alc: install bm-specific alacritty config (loaded via --config-file at spawn).
set -euo pipefail

SRC="$REPO_DIR/files/config/alacritty/bm.toml"
DST="$HOME/.config/alacritty/bm.toml"

mkdir -p "$(dirname "$DST")"
install -m 0644 "$SRC" "$DST"
echo "  alacritty bm.toml: $DST"
