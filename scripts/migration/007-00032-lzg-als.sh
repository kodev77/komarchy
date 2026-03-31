#!/usr/bin/env bash
# lazygit: bashrc: lazygit alias
set -euo pipefail

if grep -q "alias lg='lazygit'" "$HOME/.bashrc" 2>/dev/null; then
  echo "lg alias already set, skipping"
  exit 0
fi

echo "adding lg alias to bashrc..."

cat >> "$HOME/.bashrc" << 'EOF'

# --- BEGIN ko komarchy lazygit ---
alias lg='lazygit'
# --- END ko komarchy lazygit ---
EOF

echo "lg alias added"

echo ""
echo "open a new terminal to apply changes"
