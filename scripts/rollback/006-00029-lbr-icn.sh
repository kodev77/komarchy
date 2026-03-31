#!/usr/bin/env bash
# libre: rollback LibreOffice toolbar/sidebar icon size fix for HiDPI/Wayland
set -euo pipefail

XCU="$HOME/.config/libreoffice/4/user/registrymodifications.xcu"

if [[ ! -f "$XCU" ]]; then
  echo "registrymodifications.xcu not found, skipping"
  exit 0
fi

if ! grep -q 'oor:name="SymbolSet"\|<!-- BEGIN ko omarchy-setup libre-icons -->' "$XCU"; then
  echo "icon size config not found, skipping"
  exit 0
fi

echo "reverting icon sizes..."
sed -i '/<!-- BEGIN ko omarchy-setup libre-icons -->/,/<!-- END ko omarchy-setup libre-icons -->/d' "$XCU"
sed -i '/oor:name="SymbolSet"/d' "$XCU"
sed -i '/oor:name="SidebarIconSize"/d' "$XCU"
sed -i '/oor:name="NotebookbarIconSize"/d' "$XCU"
echo "icon sizes reverted"
