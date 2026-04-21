#!/usr/bin/env bash
# bm-tool: rollback bmd() rename (restore bm())
set -euo pipefail

BASHRC="$HOME/.bashrc"

if [[ ! -f "$BASHRC" ]]; then
  echo ".bashrc not found, skipping"
  exit 0
fi

if grep -q "^bm()" "$BASHRC"; then
  echo "bm() already present, skipping"
  exit 0
fi

if ! grep -q "^bmd()" "$BASHRC"; then
  echo "bmd() not found, skipping"
  exit 0
fi

sed -i 's/^bmd() {/bm() {/' "$BASHRC"
echo "  bmd() → bm(): restored"
