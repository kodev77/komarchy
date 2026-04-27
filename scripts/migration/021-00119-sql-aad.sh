#!/usr/bin/env bash
# updates: swap pymssql sqlcmd wrapper for microsoft go-sqlcmd (entra/aad auth)
set -euo pipefail

DEST="$HOME/.local/bin/sqlcmd"
GO_SQLCMD_VERSION="v1.10.0"
URL="https://github.com/microsoft/go-sqlcmd/releases/download/${GO_SQLCMD_VERSION}/sqlcmd-linux-amd64.tar.bz2"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# idempotency: skip if go-sqlcmd already installed at the target version
if [[ -x "$DEST" ]] && "$DEST" --version 2>/dev/null | grep -q "Version: ${GO_SQLCMD_VERSION}"; then
  echo "go-sqlcmd ${GO_SQLCMD_VERSION} already installed at $DEST"
  exit 0
fi

mkdir -p "$HOME/.local/bin"

echo "downloading go-sqlcmd ${GO_SQLCMD_VERSION}..."
curl -fsSL "$URL" -o "$TMP_DIR/sqlcmd.tar.bz2"

echo "extracting..."
tar -xjf "$TMP_DIR/sqlcmd.tar.bz2" -C "$TMP_DIR" sqlcmd

echo "installing to $DEST..."
install -m 755 "$TMP_DIR/sqlcmd" "$DEST"

"$DEST" --version | head -3
echo ""
echo "  sqlcmd: OK"
