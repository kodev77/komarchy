#!/usr/bin/env bash
# bm-tool-om37: keep bm tiled at exactly 300px (omarchy 3.7 / hyprland 0.54+).
# In hyprland 0.54+, `resizeactive exact W H` only resizes *floating* windows;
# on tiled bm it was a silent no-op, leaving bm at the default 50/50 split
# (and sometimes nudging the wrong window). This patches bm's two call sites
# to use a delta computed from the current width — which does work on tiles.
set -euo pipefail

BM_BIN="$HOME/.local/bin/bm"

if [[ ! -f "$BM_BIN" ]]; then
  echo "bm not installed, skipping"
  exit 2
fi

python3 - "$BM_BIN" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

# (1) Replace `resizeactive exact "$width" 100%` with delta logic that works
# on tiled windows (in hyprland 0.54+, `exact` only resizes floating windows).
# Query the window by $addr (in scope at both call sites) — `activewindow`
# races with the focuswindow dispatch and often returns stale data. Sleep
# briefly so the tile finishes settling before we measure its width.
template = '''# om37: tile delta-resize BEGIN (resizeactive exact only resizes floats in 0.54+).
# Iterate up to 4 times — under dwindle with >2 tiles, hyprland clamps a single
# big delta and only resizes partway. Each pass converges toward $width.
sleep 0.1
for _ in 1 2 3 4; do
  cur_w_=$(hyprctl clients -j 2>/dev/null | python3 -c "import json,sys; print(next((w['size'][0] for w in json.load(sys.stdin) if w.get('address')=='$addr'), 0))" 2>/dev/null) || cur_w_=0
  [[ "$cur_w_" -le 0 ]] && break
  delta_=$(( width - cur_w_ ))
  [[ "$delta_" -ge -10 && "$delta_" -le 10 ]] && break
  hyprctl dispatch resizeactive "$delta_" 0 >/dev/null 2>&1 || true
  sleep 0.15
done
# Re-assert focus on bm — chromium when freshly launched can pop up during the
# resize loop and steal focus.
hyprctl dispatch focuswindow address:"$addr" >/dev/null 2>&1 || true
# om37: tile delta-resize END
'''

def replace_resize(m):
    indent = re.match(r'^[ \t]*', m.group(0)).group(0)
    return ''.join(indent + line + '\n' for line in template.strip().split('\n'))

# Match either the pristine `resizeactive exact …` line OR any earlier om37
# patch (with or without END marker) so re-runs replace cleanly. The two
# earlier patch shapes ended at `if [[ "$cur_w_"…` (3-line) or `done` (loop).
src, n_resize = re.subn(
    r'^[ \t]*(?:hyprctl dispatch resizeactive exact[^\n]*|# om37: tile delta-resize[\s\S]*?\n[ \t]*(?:# om37: tile delta-resize END|if \[\[ "\$cur_w_"[^\n]*|done)[^\n]*)\n',
    replace_resize, src, flags=re.M,
)

# (2) Bump cdp_up's `--max-time 0.5` to `--max-time 2`. Arch's curl is built
# without c-ares, so sub-second timeouts fall back to SIGALRM (1s granularity)
# and curl aborts immediately with "remaining timeout of 500 too small to
# resolve via SIGALRM method" — meaning cdp_up always returns false even when
# chromium's CDP is live, hanging cmd_interactive in wait_for_cdp.
old_curl = 'curl -sSf -o /dev/null --max-time 0.5 '
new_curl = 'curl -sSf -o /dev/null --max-time 2 '
n_curl = src.count(old_curl)
src = src.replace(old_curl, new_curl)

if n_resize == 0 and n_curl == 0:
    print("bm already fully patched")
else:
    with open(path, 'w') as f:
        f.write(src)
    print(f"patched bm: {n_resize} resize sites + {n_curl} curl timeouts")
PY

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
