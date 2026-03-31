#!/usr/bin/env bash
# terminal: bashrc: PATH and ll alias
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup bash-alias ---' "$BASHRC"; then
  echo "bash aliases already configured, skipping"
  exit 0
fi

echo "adding PATH and ll alias to bashrc..."

cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko omarchy-setup bash-alias ---

export PATH="$HOME/.local/bin:$PATH"
alias ll='lsa'

# --- END ko omarchy-setup bash-alias ---
BASHRC

echo "bash aliases added"
