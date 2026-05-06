#!/usr/bin/env bash
# bm-tool: arm the full clean-slate wipe. 020's rollback removes
# ~/.config/bm/ (chromium profile + any remaining UI state) — what
# 019's rollback preserves for the fast rollback→migrate dev loop.
# saved-tabs.json is not in scope: it lives in the repo working tree
# as the cross-machine sync source of truth and must never be touched
# by a rollback.
set -euo pipefail

BM_STATE_DIR="$HOME/.config/bm"

if [[ -d "$BM_STATE_DIR" ]]; then
  echo "  bm state/profile dir: present — rollback will wipe ($BM_STATE_DIR)"
else
  echo "  bm state/profile dir: not present (chromium creates on first launch)"
fi
