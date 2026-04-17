#!/usr/bin/env bash
# terminal: starship identity colors (user/host/@/prompt arrow/error) track omarchy accent via theme-set hook
set -euo pipefail

BIN="$HOME/.local/bin"
HOOKS="$HOME/.config/omarchy/hooks"
APPLY_SCRIPT="$BIN/komarchy-starship-theme-apply"
THEME_SET_HOOK="$HOOKS/theme-set"

mkdir -p "$BIN" "$HOOKS"

echo "installing komarchy-starship-theme-apply..."

cat > "$APPLY_SCRIPT" << 'BASHEOF'
#!/usr/bin/env bash
# apply omarchy theme accent to starship identity/prompt elements.
# theme -> hue bucket mapping mirrors ~/.config/nvim/plugin/after/neotree-hue.lua
set -euo pipefail

COLORS="$HOME/.config/omarchy/current/theme/colors.toml"
STARSHIP="$HOME/.config/starship.toml"
THEME_NAME_FILE="$HOME/.config/omarchy/current/theme.name"

[[ -f "$COLORS" && -f "$STARSHIP" ]] || exit 0

toml_color() {
  awk -F'"' -v k="$1" '$0 ~ "^"k"[[:space:]]*=" {print $2; exit}' "$COLORS"
}

accent=$(toml_color accent)
[[ -n "$accent" ]] || exit 0

theme=$(tr -d '[:space:]' < "$THEME_NAME_FILE" 2>/dev/null || true)

# theme -> hue bucket (mirror the neotree-hue.lua mapping)
hue=""
case "$theme" in
  osaka-jade) hue="green" ;;
  gruvbox)    hue="green" ;;
  miasma)     hue="green" ;;
  # tokyo-night)        hue="dark"  ;;
  # catppuccin)         hue="purple" ;;
  # catppuccin-latte)   hue="light" ;;
  # rose-pine)          hue="purple" ;;
esac

# per-hue prompt-arrow override: buckets where the accent collides with the
# directory/path color get a distinct slot so the arrow pops visually
arrow="$accent"
case "$hue" in
  green) arrow=$(toml_color color6) ;;
esac
[[ -n "$arrow" ]] || arrow="$accent"

sed -i -E \
  -e 's|(\[\$user\]\(bold )[^)]+(\))|\1'"$accent"'\2|' \
  -e 's|(\[\$hostname\]\(bold )[^)]+(\))|\1'"$accent"'\2|' \
  -e 's|(\$username\[@\]\(bold )[^)]+(\))|\1'"$accent"'\2|' \
  -e 's|(\[[^]]+\]\(bold )[^)]+(\)\$character)|\1'"$arrow"'\2|' \
  -e 's|(error_symbol = "\[[^]]+\]\(bold )[^)]+(\))|\1'"$accent"'\2|' \
  "$STARSHIP"
BASHEOF
chmod +x "$APPLY_SCRIPT"
echo "  wrote $APPLY_SCRIPT"

# wire the theme-set hook — create if missing, append if present without our call
# absolute path needed because omarchy-theme-set can run under minimal PATH
# (walker / keybinding / systemd contexts don't always include ~/.local/bin)
if [[ ! -f "$THEME_SET_HOOK" ]]; then
  cat > "$THEME_SET_HOOK" << 'HOOKEOF'
#!/bin/bash
# omarchy theme-set hook: invoked with snake-cased theme name as $1

"$HOME/.local/bin/komarchy-starship-theme-apply" 2>/dev/null || true
HOOKEOF
  chmod +x "$THEME_SET_HOOK"
  echo "  created $THEME_SET_HOOK"
else
  # drop any prior komarchy-starship-theme-apply invocation, then append the correct absolute-path form
  sed -i '/komarchy-starship-theme-apply/d' "$THEME_SET_HOOK"
  printf '\n"$HOME/.local/bin/komarchy-starship-theme-apply" 2>/dev/null || true\n' >> "$THEME_SET_HOOK"
  echo "  normalized $THEME_SET_HOOK invocation to absolute path"
fi

# apply once so current theme takes effect
"$APPLY_SCRIPT"
echo "  starship.toml: accent applied for current theme"
