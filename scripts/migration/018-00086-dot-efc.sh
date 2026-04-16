#!/usr/bin/env bash
# updates: install dotnet-ef global tool and add ~/.dotnet/tools to PATH
set -euo pipefail

BASHRC="$HOME/.bashrc"

if ! command -v dotnet &>/dev/null; then
  echo "dotnet not found, run group 012 first"
  exit 2
fi

if dotnet tool list --global 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx 'dotnet-ef'; then
  echo "dotnet-ef already installed"
else
  echo "installing dotnet-ef global tool..."
  dotnet tool install --global dotnet-ef
  echo "  dotnet-ef: OK"
fi

if grep -q '# --- BEGIN ko komarchy dotnet-tools-path ---' "$BASHRC"; then
  echo "dotnet tools PATH already configured"
else
  echo "adding ~/.dotnet/tools to PATH in bashrc..."
  cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko komarchy dotnet-tools-path ---
export PATH="$PATH:$HOME/.dotnet/tools"
# --- END ko komarchy dotnet-tools-path ---
BASHRC
  echo "  PATH: OK"
fi

echo ""
echo "open a new terminal or run: source ~/.bashrc"
