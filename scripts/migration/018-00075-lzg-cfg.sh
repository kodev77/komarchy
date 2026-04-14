#!/usr/bin/env bash
# updates: lazygit config: flat file view and detailed log with author and time
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"

if [[ ! -f "$CONFIG" ]]; then
  echo "lazygit config not found, skipping"
  exit 2
fi

echo "patching lazygit config..."

# flat file view
if grep -q 'showFileTree' "$CONFIG"; then
  echo "showFileTree already configured"
else
  if grep -q '^gui:' "$CONFIG"; then
    sed -i '/^gui:/a\  showFileTree: false' "$CONFIG"
  else
    cat >> "$CONFIG" << 'EOF'
gui:
  showFileTree: false
EOF
  fi
  echo "flat file view set"
fi

# detailed log with author and relative time (git lg2 format)
LG2_FMT="%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset) %C(bold green)- %an%C(reset) %C(dim bold green)(%ar)%C(reset)%C(auto)%d%C(reset)"

# allBranchesLogCmds: insert lg2 as first entry (Status panel, cycle with 'a')
if grep -q '^  allBranchesLogCmds:' "$CONFIG" && ! grep -q '%an.*allBranchesLogCmds\|allBranchesLogCmds.*%an' "$CONFIG" && ! sed -n '/allBranchesLogCmds/,/^  [^ ]/p' "$CONFIG" | grep -q '%an'; then
  sed -i "/^  allBranchesLogCmds:/a\\    - \"git log --graph --all --color=always --abbrev-commit --decorate --format=format:'$LG2_FMT'\"" "$CONFIG"
  echo "lg2 allBranchesLogCmds entry added"
else
  echo "lg2 allBranchesLogCmds already configured"
fi

# branchLogCmd: replace with lg2 format (Local Branches panel [3])
if grep -q 'branchLogCmd' "$CONFIG" && ! grep -q 'branchLogCmd.*%an' "$CONFIG"; then
  sed -i "s|^  branchLogCmd:.*|  branchLogCmd: \"git log --graph --color=always --abbrev-commit --decorate --format=format:'$LG2_FMT' {{branchName}} --\"|" "$CONFIG"
  echo "lg2 branchLogCmd set"
else
  echo "lg2 branchLogCmd already configured"
fi

echo "lazygit config patched"
