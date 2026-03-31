#!/usr/bin/env bash
# terminal: rollback starship config
set -euo pipefail

STARSHIP="$HOME/.config/starship.toml"

if [[ ! -f "$STARSHIP" ]]; then
  echo "starship.toml not found, skipping"
  exit 0
fi

echo "reverting starship config..."

# prompt format line - only the top-level format (line 3)
sed -i '3s|^format = .*|format = "[$directory$git_branch$git_status]($style)$character"|' "$STARSHIP"

# character symbols
sed -i 's/^error_symbol = "\[✗\](bold cyan) "$/error_symbol = "[✗](bold cyan)"/' "$STARSHIP"
sed -i 's/^success_symbol = ""$/success_symbol = "[❯](bold cyan)"/' "$STARSHIP"

# directory settings
sed -i 's/^truncation_length = 0$/truncation_length = 2/' "$STARSHIP"
sed -i 's/^truncation_symbol = ""$/truncation_symbol = "…\/"/' "$STARSHIP"

# remove added directory settings
sed -i '/^truncate_to_repo = false$/d' "$STARSHIP"
sed -i '/^home_symbol = "~"$/d' "$STARSHIP"
sed -i '/^style = "bold cyan"$/d' "$STARSHIP"
sed -i '/^format = "⟩ \[\$path\]/d' "$STARSHIP"

# repo root format
sed -i 's|^repo_root_format = "⟩ \[\$repo_root\]|repo_root_format = "[$repo_root]|' "$STARSHIP"

# git branch style
sed -i 's/^format = " \[\$branch\](\$style) "$/format = "[$branch]($style) "/' "$STARSHIP"
sed -i 's/^style = "bold #f5a623"$/style = "italic cyan"/' "$STARSHIP"

# remove username/hostname sections
sed -i '/^\[username\]$/,/^$/d' "$STARSHIP"
sed -i '/^\[hostname\]$/,/^$/d' "$STARSHIP"

echo "starship.toml reverted"
echo ""
echo "close all open terminals and open a new terminal to see changes"
