#!/usr/bin/env bash
# waybar: rollback always-visible tray (restore tray-expander drawer)
set -euo pipefail

CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$CONFIG" ]]; then
  echo "waybar config.jsonc not found, skipping"
  exit 0
fi

# Only revert the modules-right entry (4-space indent + trailing comma),
# not the "tray": { ... } definition block (2-space indent + colon)
if ! grep -qE '^    "tray",$' "$CONFIG"; then
  echo "  waybar modules-right: tray entry not present, nothing to roll back"
  exit 0
fi

sed -i 's|^    "tray",$|    "group/tray-expander",|' "$CONFIG"
echo "  waybar config.jsonc: modules-right restored to \"group/tray-expander\""

echo ""
echo "reload waybar to apply: pkill -SIGUSR2 waybar"
