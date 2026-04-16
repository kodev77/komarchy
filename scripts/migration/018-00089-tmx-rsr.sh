#!/usr/bin/env bash
# tmux: install tmux-resurrect for on-demand session save/restore
set -euo pipefail

TMUX_CONF="$HOME/.config/tmux/tmux.conf"
PLUGINS_DIR="$HOME/.config/tmux/plugins"
TPM_DIR="$PLUGINS_DIR/tpm"
RESURRECT_DIR="$PLUGINS_DIR/tmux-resurrect"
SENTINEL_BEGIN="# komarchy: tmux-resurrect BEGIN"
SENTINEL_END="# komarchy: tmux-resurrect END"

if ! command -v tmux &>/dev/null; then
  echo "tmux not installed, skipping"
  exit 2
fi

if [[ ! -f "$TMUX_CONF" ]]; then
  echo "tmux config not found at $TMUX_CONF, skipping"
  exit 2
fi

mkdir -p "$PLUGINS_DIR"

if [[ ! -d "$TPM_DIR" ]]; then
  echo "cloning tpm..."
  git clone --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "tpm already present"
fi

if [[ ! -d "$RESURRECT_DIR" ]]; then
  echo "cloning tmux-resurrect..."
  git clone --depth 1 https://github.com/tmux-plugins/tmux-resurrect "$RESURRECT_DIR"
else
  echo "tmux-resurrect already present"
fi

if grep -qF "$SENTINEL_BEGIN" "$TMUX_CONF"; then
  echo "tmux.conf already patched"
  exit 0
fi

echo "appending tmux-resurrect block to $TMUX_CONF..."
cat >> "$TMUX_CONF" << 'EOF'

# komarchy: tmux-resurrect BEGIN
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
run '~/.config/tmux/plugins/tpm/tpm'
# komarchy: tmux-resurrect END
EOF

echo ""
echo "activate:"
echo "  - in a running tmux: press 'Prefix + q' to reload config"
echo "  - or start a fresh tmux session"
echo ""
echo "usage:"
echo "  Prefix + Ctrl-s   save snapshot of all sessions"
echo "  Prefix + Ctrl-r   restore snapshot after reboot"
echo "  snapshots saved to ~/.local/share/tmux/resurrect/"
