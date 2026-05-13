#!/usr/bin/env bash
# updates-om37: rollback alacritty font to JetBrainsMono Nerd Font
set -euo pipefail

ALACRITTY_CFG="$HOME/.config/alacritty/alacritty.toml"

if [[ ! -f "$ALACRITTY_CFG" ]]; then
  echo "alacritty config not found, skipping"
  exit 0
fi

echo "reverting alacritty font..."
sed -i 's/family = "Berkeley Mono", style = "Oblique"/family = "Berkeley Mono", style = "Italic"/' "$ALACRITTY_CFG"
sed -i 's/family = "Berkeley Mono"/family = "JetBrainsMono Nerd Font"/g' "$ALACRITTY_CFG"
sed -i 's/^size = 13$/size = 9/' "$ALACRITTY_CFG"
echo "alacritty font reverted"
