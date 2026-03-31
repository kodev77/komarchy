#!/usr/bin/env bash
# lazygit: lazygit config: custom log format with short hash, dim message, and auto decorations
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"

if [[ -f "$CONFIG" ]] && grep -q 'branchLogCmd' "$CONFIG"; then
  echo "lazygit config already set, skipping"
  exit 0
fi

echo "patching lazygit config..."

mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" << 'EOF'
git:
  log:
    showWholeGraph: false
  branchLogCmd: "git log --graph --color=always --abbrev-commit --decorate --format=format:'%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset)%C(auto)%d%C(reset)' {{branchName}} --"
  allBranchesLogCmds:
    - "git log --graph --all --color=always --abbrev-commit --decorate --format=format:'%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset)%C(auto)%d%C(reset)'"
EOF

echo "lazygit config set"
