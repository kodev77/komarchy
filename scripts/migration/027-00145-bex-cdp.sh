#!/usr/bin/env bash
# bm-chromium: enable chromium's remote debugging port so bm-ext-focus
# can use CDP to focus the side panel when it's already open.
#
# Adds `--remote-debugging-port=9222` to ~/.config/chromium-flags.conf.
# Chromium reads this file at launch, so the flag takes effect on the
# next chromium start. The CDP server listens on localhost only — no
# external network exposure.

set -euo pipefail

FLAGS="$HOME/.config/chromium-flags.conf"
FLAG='--remote-debugging-port=9222'

mkdir -p "$(dirname "$FLAGS")"
touch "$FLAGS"

if grep -qxF "$FLAG" "$FLAGS"; then
  echo "chromium remote debugging port already enabled in $FLAGS"
  exit 0
fi

echo "$FLAG" >> "$FLAGS"
echo "added $FLAG to $FLAGS"
echo ""
echo "restart chromium for the flag to take effect"
echo "(close all chromium windows, then relaunch)"
