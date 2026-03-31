#!/usr/bin/env bash
# libre: LibreOffice toolbar/sidebar icon size fix for HiDPI/Wayland
set -euo pipefail

XCU="$HOME/.config/libreoffice/4/user/registrymodifications.xcu"

if [[ ! -f "$XCU" ]]; then
  echo "registrymodifications.xcu not found, skipping"
  echo "open LibreOffice once first to generate config"
  exit 2
fi

if grep -q 'oor:name="SymbolSet"' "$XCU"; then
  echo "icon size already configured, skipping"
  exit 0
fi

echo "patching registrymodifications.xcu..."

sed -i '/<\/oor:items>/i \
<!-- BEGIN ko omarchy-setup libre-icons -->\
<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="SymbolSet" oor:op="fuse"><value>0</value></prop></item>\
<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="SidebarIconSize" oor:op="fuse"><value>0</value></prop></item>\
<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="NotebookbarIconSize" oor:op="fuse"><value>0</value></prop></item>\
<!-- END ko omarchy-setup libre-icons -->' "$XCU"

echo "icon sizes set to small"
