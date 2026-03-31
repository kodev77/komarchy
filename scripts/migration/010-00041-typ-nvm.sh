#!/usr/bin/env bash
# typescript: lazyvim extra: typescript language support
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"
if [[ -f "$LAZYVIM" ]] && ! grep -q "lazyvim.plugins.extras.lang.typescript" "$LAZYVIM"; then
  sed -i 's|"lazyvim.plugins.extras.editor.neo-tree"|"lazyvim.plugins.extras.editor.neo-tree",\n    "lazyvim.plugins.extras.lang.typescript"|' "$LAZYVIM"
fi
echo "  lazyvim extra: lang.typescript"
