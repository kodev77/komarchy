#!/usr/bin/env bash
# retro: hyprland windowrule — force linapple emulator to tile instead of
# float. SDL 1.2 hints linapple as a transient floating window by default;
# this rule overrides that so the emulator joins the tiled layout.
set -euo pipefail

LOOKFEEL="$HOME/.config/hypr/looknfeel.conf"

LNA_RULE_BEGIN="# --- BEGIN ko komarchy linapple windowrules ---"
LNA_RULE_END="# --- END ko komarchy linapple windowrules ---"

if [[ ! -f "$LOOKFEEL" ]]; then
  echo "  looknfeel.conf: not found, skipping"
  exit 2
fi

if grep -qF "$LNA_RULE_BEGIN" "$LOOKFEEL"; then
  echo "  looknfeel.conf: already patched"
else
  cat >> "$LOOKFEEL" <<EOF

$LNA_RULE_BEGIN
# linapple uses SDL 1.2 (via sdl12-compat) which sets ICCCM/WM_NORMAL_HINTS
# with PMinSize == PMaxSize. Hyprland silently ignores tile/float/size/move
# rules on such windows — only fullscreen and tag/visual rules slip through.
# Same trap as RetroArch in stock omarchy (apps/retroarch.conf). Rather than
# force fullscreen, we let the floating window open at whatever size SDL
# requests (controlled by Screen factor in linapple.conf — typically 2-3x
# the native 560x384) and just center it on the workspace. User can hit
# Super+F to fullscreen anytime.
windowrule = tag +linapple-window, match:class ^(linapple)\$
windowrule = center on, match:tag linapple-window
$LNA_RULE_END
EOF
  echo "  looknfeel.conf: linapple tile rule added"
fi

echo ""
echo "reload hyprland to apply: hyprctl reload"
