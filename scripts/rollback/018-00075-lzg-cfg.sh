#!/usr/bin/env bash
# updates: rollback lazygit config: flat file view and detailed log with author and time
set -euo pipefail

CONFIG="$HOME/.config/lazygit/config.yml"
ORIG_FMT="%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset)%C(auto)%d%C(reset)"

if [[ ! -f "$CONFIG" ]]; then
  echo "lazygit config not found, skipping"
  exit 0
fi

echo "rolling back lazygit config..."

# restore original branchLogCmd first (before the delete that would remove it)
if grep -q 'branchLogCmd' "$CONFIG"; then
  sed -i "s|^  branchLogCmd:.*|  branchLogCmd: \"git log --graph --color=always --abbrev-commit --decorate --format=format:'$ORIG_FMT' {{branchName}} --\"|" "$CONFIG"
else
  # branchLogCmd was removed somehow, re-add it after the log: section
  sed -i "/^  log:/a\\  branchLogCmd: \"git log --graph --color=always --abbrev-commit --decorate --format=format:'$ORIG_FMT' {{branchName}} --\"" "$CONFIG"
fi
echo "branchLogCmd restored"

# remove lg2 allBranchesLogCmds entry only (the line with %an under allBranchesLogCmds)
sed -i '/allBranchesLogCmds/,/^  [^ ]/{/- .*%an/d;}' "$CONFIG"
echo "lg2 allBranchesLogCmds entry removed"

# remove showFileTree
sed -i '/^  showFileTree: false$/d' "$CONFIG"

# clean up empty gui: section
if grep -q '^gui:' "$CONFIG"; then
  if ! sed -n '/^gui:/,/^[^ ]/p' "$CONFIG" | grep -q '^  '; then
    sed -i '/^gui:$/d' "$CONFIG"
  fi
fi

echo "lazygit config rolled back"
