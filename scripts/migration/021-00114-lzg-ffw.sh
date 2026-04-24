#!/usr/bin/env bash
# updates: lazygit config: disable auto-fast-forward so main/master is never
# silently advanced when fetching — review first, then fast-forward manually
# with the `f` keybind.
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"

if [[ ! -f "$CONFIG" ]]; then
  echo "lazygit config not found, skipping"
  exit 2
fi

echo "patching lazygit config..."

if grep -q '^  autoForwardBranches:' "$CONFIG"; then
  echo "autoForwardBranches already configured"
else
  if grep -q '^git:' "$CONFIG"; then
    sed -i '/^git:/a\  autoForwardBranches: none' "$CONFIG"
  else
    cat >> "$CONFIG" << 'EOF'
git:
  autoForwardBranches: none
EOF
  fi
  echo "autoForwardBranches set to none"
fi

echo "lazygit config patched"
