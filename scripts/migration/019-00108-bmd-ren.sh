#!/usr/bin/env bash
# bm-tool: rename bm() bash function to bmd() (frees `bm` as a command)
set -euo pipefail

BASHRC="$HOME/.bashrc"

if [[ ! -f "$BASHRC" ]]; then
  echo ".bashrc not found, skipping"
  exit 0
fi

if grep -q "^bmd()" "$BASHRC"; then
  echo "bmd() already present, skipping"
  exit 0
fi

if ! grep -q "^bm()" "$BASHRC"; then
  echo "bm() not found in .bashrc, skipping"
  exit 0
fi

# Rename function name and update the comment header if present.
sed -i 's/^bm() {/bmd() {/' "$BASHRC"
echo "  bm() → bmd(): renamed"
echo ""
echo "open a new terminal to use: bmd, bmd ko, bmd rpc"
