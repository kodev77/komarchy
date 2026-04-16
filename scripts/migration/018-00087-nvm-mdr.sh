#!/usr/bin/env bash
# neovim: lazyvim extra: markdown (render-markdown, marksman, markdown-toc)
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"
if [[ -f "$LAZYVIM" ]] && ! grep -q "lazyvim.plugins.extras.lang.markdown" "$LAZYVIM"; then
  sed -i 's|"lazyvim.plugins.extras.dap.core"|"lazyvim.plugins.extras.dap.core",\n    "lazyvim.plugins.extras.lang.markdown"|' "$LAZYVIM"
fi
echo "  lazyvim extra: lang.markdown"
