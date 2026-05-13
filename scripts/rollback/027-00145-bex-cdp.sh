#!/usr/bin/env bash
# bm-chromium: rollback the chromium remote-debugging-port flag
set -euo pipefail

FLAGS="$HOME/.config/chromium-flags.conf"
FLAG='--remote-debugging-port=9222'

if [[ ! -f "$FLAGS" ]]; then
  echo "chromium-flags.conf not present, nothing to roll back"
  exit 0
fi

if ! grep -qxF "$FLAG" "$FLAGS"; then
  echo "$FLAG not present in $FLAGS, nothing to roll back"
  exit 0
fi

# Match the exact line; preserve other flags.
sed -i "\|^${FLAG//\//\\/}\$|d" "$FLAGS"
echo "removed $FLAG from $FLAGS"
echo "restart chromium for the change to take effect"
