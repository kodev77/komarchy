#!/usr/bin/env bash
# berkeley: rollback ghostty font to JetBrainsMono
set -euo pipefail

GHOSTTY_CFG="$HOME/.config/ghostty/config"

if [[ ! -f "$GHOSTTY_CFG" ]]; then
  echo "ghostty config not found, skipping"
  exit 0
fi

echo "reverting ghostty font..."
sed -i 's/font-family = "Berkeley Mono"/font-family = "JetBrainsMono Nerd Font"/' "$GHOSTTY_CFG"
sed -i 's/font-family = Berkeley Mono/font-family = JetBrainsMono Nerd Font/' "$GHOSTTY_CFG"
echo "ghostty font reverted"
