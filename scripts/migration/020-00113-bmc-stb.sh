#!/usr/bin/env bash
# bm-tool: arm the full clean-slate wipe. 020's rollback removes both
# ~/.config/omarchy/bm/saved-tabs.json AND ~/.config/bm/ (chromium
# profile + any remaining UI state) — items 019's rollback preserves
# for the fast rollback→migrate dev loop.
set -euo pipefail

SAVED="$HOME/.config/omarchy/bm/saved-tabs.json"
BM_STATE_DIR="$HOME/.config/bm"

if [[ -f "$SAVED" ]]; then
  echo "  saved-tabs.json: present — rollback will wipe ($SAVED)"
else
  echo "  saved-tabs.json: not present (019-00111 seeds it)"
fi

if [[ -d "$BM_STATE_DIR" ]]; then
  echo "  bm state/profile dir: present — rollback will wipe ($BM_STATE_DIR)"
else
  echo "  bm state/profile dir: not present (chromium creates on first launch)"
fi
