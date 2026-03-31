#!/usr/bin/env bash
# hello: work-specific git config for rpc repos
set -euo pipefail

echo "writing gitconfig.work..."

cat > "$HOME/.gitconfig.work" << 'GITWORK'
# Work-specific git config (loaded for ~/rpc/repo/ paths)

[user]
	name = KOrtego20170
	email = KOrtego20170@rpc.net
GITWORK

echo "gitconfig.work applied"
