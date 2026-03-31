#!/usr/bin/env bash
# terminal: starship patches: two-line prompt with user@host, full path, git branch color, no truncation
set -euo pipefail

STARSHIP="$HOME/.config/starship.toml"

if [[ ! -f "$STARSHIP" ]]; then
  echo "starship.toml not found, skipping"
  exit 0
fi

echo "patching starship config..."

# prompt format line
sed -i 's|^format = "\[\$directory\$git_branch\$git_status\](\$style)\$character"|format = "$username[@](bold bright-green)$hostname $directory$git_branch$git_status\\n[ ](bold cyan)$character"|' "$STARSHIP"

# character symbols
sed -i 's/^error_symbol = "\[✗\](bold cyan)"$/error_symbol = "[✗](bold cyan) "/' "$STARSHIP"
sed -i 's/^success_symbol = "\[❯\](bold cyan)"$/success_symbol = ""/' "$STARSHIP"

# directory settings
sed -i 's/^truncation_length = 2$/truncation_length = 0/' "$STARSHIP"
sed -i 's/^truncation_symbol = "…\/"/truncation_symbol = ""/' "$STARSHIP"

# add directory settings if missing
if ! grep -q 'truncate_to_repo' "$STARSHIP"; then
  sed -i '/^truncation_length = 0$/a\truncate_to_repo = false' "$STARSHIP"
fi
if ! grep -q 'home_symbol' "$STARSHIP"; then
  sed -i '/^truncation_symbol = ""$/a\home_symbol = "~"\nstyle = "bold cyan"\nformat = "⟩ [$path]($style)[$read_only]($read_only_style) "' "$STARSHIP"
fi

# repo root format
sed -i 's|^repo_root_format = "\[\$repo_root\]|repo_root_format = "⟩ [$repo_root]|' "$STARSHIP"

# git branch style
sed -i 's/^format = "\[\$branch\](\$style) "$/format = " [$branch]($style) "/' "$STARSHIP"
sed -i 's/^style = "italic cyan"$/style = "bold #f5a623"/' "$STARSHIP"

# add username/hostname sections if missing
if ! grep -q '\[username\]' "$STARSHIP"; then
  cat >> "$STARSHIP" << 'EOF'

[username]
show_always = true
format = "[$user](bold bright-green)"

[hostname]
ssh_only = false
format = "[$hostname](bold bright-green)"
EOF
fi

echo "starship.toml patched"
