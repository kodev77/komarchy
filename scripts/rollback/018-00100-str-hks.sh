#!/usr/bin/env bash
# terminal: rollback theme-set hook + accent injection (restore palette-name colors for identity/prompt)
set -euo pipefail

BIN="$HOME/.local/bin"
HOOKS="$HOME/.config/omarchy/hooks"
APPLY_SCRIPT="$BIN/komarchy-starship-theme-apply"
THEME_SET_HOOK="$HOOKS/theme-set"
STARSHIP="$HOME/.config/starship.toml"

# remove the hook invocation; if the hook file is then effectively empty, delete it
if [[ -f "$THEME_SET_HOOK" ]]; then
  sed -i '/komarchy-starship-theme-apply/d' "$THEME_SET_HOOK"
  if [[ $(grep -cvE '^\s*(#!|#|$)' "$THEME_SET_HOOK") -eq 0 ]]; then
    rm -f "$THEME_SET_HOOK"
    echo "  removed empty $THEME_SET_HOOK"
  else
    echo "  cleaned hook line from $THEME_SET_HOOK"
  fi
fi

if [[ -f "$APPLY_SCRIPT" ]]; then
  rm -f "$APPLY_SCRIPT"
  echo "  removed $APPLY_SCRIPT"
fi

# restore palette-name colors where the apply script had injected hex
if [[ -f "$STARSHIP" ]]; then
  sed -i -E \
    -e 's|(\[\$user\]\(bold )#[0-9a-fA-F]+(\))|\1bright-green\2|' \
    -e 's|(\[\$hostname\]\(bold )#[0-9a-fA-F]+(\))|\1bright-green\2|' \
    -e 's|(\$username\[@\]\(bold )#[0-9a-fA-F]+(\))|\1bright-green\2|' \
    -e 's|(\[[^]]+\]\(bold )#[0-9a-fA-F]+(\)\$character)|\1cyan\2|' \
    -e 's|(error_symbol = "\[[^]]+\]\(bold )#[0-9a-fA-F]+(\))|\1cyan\2|' \
    "$STARSHIP"
  echo "  starship.toml: restored palette-name colors for identity/prompt"
fi
