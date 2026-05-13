#!/usr/bin/env bash
# bm-tool-alc: rollback is a deliberate no-op.
# The ghostty-coupled bm binary from group 019 doesn't run on om37
# (ghostty isn't installed), so reverting to it has no practical value.
# Leaving the alacritty version in place keeps the user with a working
# tool even after rollback.
set -euo pipefail
echo "  bm launcher: rollback is no-op (kept alacritty version)"
