#!/usr/bin/env bash
# updates: rollback dotnet-ef global tool and PATH entry
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy dotnet-tools-path ---' "$BASHRC"; then
  echo "removing dotnet tools PATH from bashrc..."
  sed -i '/# --- BEGIN ko komarchy dotnet-tools-path ---/,/# --- END ko komarchy dotnet-tools-path ---/d' "$BASHRC"
  echo "  PATH: removed"
else
  echo "dotnet tools PATH not in bashrc, skipping"
fi

if command -v dotnet &>/dev/null && \
   dotnet tool list --global 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx 'dotnet-ef'; then
  echo "uninstalling dotnet-ef global tool..."
  dotnet tool uninstall --global dotnet-ef
  echo "  dotnet-ef: removed"
else
  echo "dotnet-ef not installed, skipping"
fi
