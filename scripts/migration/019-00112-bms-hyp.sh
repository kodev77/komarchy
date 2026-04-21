#!/usr/bin/env bash
# bm-tool: append hyprland window rules + Super+Alt+hjkl leader keybinds
set -euo pipefail

BINDINGS="$HOME/.config/hypr/bindings.conf"
LOOKFEEL="$HOME/.config/hypr/looknfeel.conf"

BM_BIND_BEGIN="# --- BEGIN ko komarchy bm-tool bindings ---"
BM_BIND_END="# --- END ko komarchy bm-tool bindings ---"
BM_RULE_BEGIN="# --- BEGIN ko komarchy bm-tool windowrules ---"
BM_RULE_END="# --- END ko komarchy bm-tool windowrules ---"

if [[ -f "$BINDINGS" ]]; then
  if grep -qF "$BM_BIND_BEGIN" "$BINDINGS"; then
    echo "  bindings.conf: already patched"
  else
    cat >> "$BINDINGS" <<EOF

$BM_BIND_BEGIN
# Vim-key leader block for the bm + chromium sidebar workflow. Super+Alt
# is chosen because H/J/K/L are unbound there at every layer (stock
# omarchy uses Super+J/K/L for window-split/keybinds/layout, which stay
# intact). All four exec absolute paths because hyprland's PATH doesn't
# include ~/.local/bin in default omarchy setups.
bindd = SUPER ALT, H, bm sidebar,    exec, \$HOME/.local/bin/bm focus
bindd = SUPER ALT, J, bm next tab,   exec, \$HOME/.local/bin/bm next
bindd = SUPER ALT, K, bm prev tab,   exec, \$HOME/.local/bin/bm prev
bindd = SUPER ALT, L, focus browser, exec, hyprctl dispatch focuswindow class:chromium
$BM_BIND_END
EOF
    echo "  bindings.conf: Super+Alt+hjkl block added"
  fi
else
  echo "  bindings.conf: not found, skipping"
fi

if [[ -f "$LOOKFEEL" ]]; then
  if grep -qF "$BM_RULE_BEGIN" "$LOOKFEEL"; then
    echo "  looknfeel.conf: already patched"
  else
    cat >> "$LOOKFEEL" <<EOF

$BM_RULE_BEGIN
# bm runs with ghostty background-opacity=0 so the desktop shows through.
# Hyprland's global blur provides the frosted-glass look. no_shadow drops
# the dark drop-shadow rim. The default omarchy border stays on so bm
# matches the visual language of other ghostty windows.
windowrule = no_shadow on, match:class com.ko.bm
$BM_RULE_END
EOF
    echo "  looknfeel.conf: bm windowrules added (no_blur)"
  fi
else
  echo "  looknfeel.conf: not found, skipping"
fi

echo ""
echo "reload hyprland to apply: hyprctl reload"
