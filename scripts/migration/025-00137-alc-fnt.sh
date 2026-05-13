#!/usr/bin/env bash
# updates-om37: alacritty: swap font to Berkeley Mono (om37 ships alacritty as default)
set -euo pipefail

ALACRITTY_CFG="$HOME/.config/alacritty/alacritty.toml"

if [[ ! -f "$ALACRITTY_CFG" ]]; then
  echo "alacritty config not found, skipping"
  exit 0
fi

if ! ls "$HOME/.local/share/fonts"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 2
fi

if ! grep -q 'family = "JetBrainsMono Nerd Font"' "$ALACRITTY_CFG"; then
  echo "alacritty font already patched (no JetBrainsMono lines), skipping"
  exit 0
fi

echo "patching alacritty font..."
sed -i 's/family = "JetBrainsMono Nerd Font"/family = "Berkeley Mono"/g' "$ALACRITTY_CFG"
# Berkeley Mono ships "Oblique" rather than "Italic" — match the actual style name
sed -i 's/family = "Berkeley Mono", style = "Italic"/family = "Berkeley Mono", style = "Oblique"/' "$ALACRITTY_CFG"
# Size bump: 9 was sized for JetBrainsMono; 13 matches the prior ghostty Berkeley setup
sed -i 's/^size = 9$/size = 13/' "$ALACRITTY_CFG"
echo "alacritty font patched"

echo ""
echo "close all open terminals and open a new terminal to see changes"
