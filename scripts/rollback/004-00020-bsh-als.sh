#!/usr/bin/env bash
# terminal: rollback bash aliases
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy bash-alias ---' "$BASHRC"; then
  echo "removing bash aliases..."
  sed -i '/# --- BEGIN ko komarchy bash-alias ---/,/# --- END ko komarchy bash-alias ---/d' "$BASHRC"
  echo "bash aliases removed"
else
  echo "bash aliases not found, skipping"
fi
