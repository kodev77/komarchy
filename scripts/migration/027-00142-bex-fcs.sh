#!/usr/bin/env bash
# bm-chromium: install bm-ext-focus script into ~/.local/bin
set -euo pipefail

SRC="$REPO_DIR/files/local/bin/bm-ext-focus"
DST="$HOME/.local/bin/bm-ext-focus"

if [[ ! -f "$SRC" ]]; then
  echo "bm-ext-focus source not found at $SRC, skipping"
  exit 2
fi

if ! command -v wtype &>/dev/null; then
  echo "wtype not installed (run 027-00139-bex-pkg first), skipping"
  exit 2
fi

mkdir -p "$(dirname "$DST")"
install -m 0755 "$SRC" "$DST"
echo "installed $DST"
