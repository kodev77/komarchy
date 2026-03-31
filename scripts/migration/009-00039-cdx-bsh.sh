#!/usr/bin/env bash
# neovim-cdexit: bash nvim cwd hook and cursor styling
set -euo pipefail

if grep -q '__nvim_cwd_hook' "$HOME/.bashrc" 2>/dev/null; then
  echo "nvim cwd hook already set, skipping"
  exit 0
fi

echo "adding nvim cwd hook and cursor styling to bashrc..."

cat >> "$HOME/.bashrc" << 'EOF'

# --- BEGIN ko komarchy nvim-cdexit ---
# Pick up nvim cwd-on-exit when prompt returns
__nvim_cwd_hook() {
  if [ -f ~/.nvim_cwd ]; then
    local dir
    dir="$(command cat ~/.nvim_cwd)"
    rm -f ~/.nvim_cwd
    [ -n "$dir" ] && [ "$dir" != "$PWD" ] && builtin cd -- "$dir"
  fi
}
# Set blinking block cursor
__set_cursor() { printf '\e[1 q\e]12;#D7C995\a'; }
PROMPT_COMMAND="__nvim_cwd_hook;__set_cursor;${PROMPT_COMMAND}"
# --- END ko komarchy nvim-cdexit ---
EOF

echo "  bash nvim hook + cursor: OK"

echo ""
echo "open a new terminal to apply changes"
