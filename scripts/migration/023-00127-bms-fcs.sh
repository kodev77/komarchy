#!/usr/bin/env bash
# bm-tool-om37: bm focus by class (orphan ghostty fix). On 3.7+, ghostty's bm
# window can be closed without ghostty exiting, leaving an orphan ghostty + bm-py
# pair alive. find_bm_ghostty_pid's `pgrep -x bm-py | head -1` returns the OLDEST
# bm-py (often the orphan), focus_hyprland_window_by_pid then fails (no window
# for that PID), and cmd_focus spawns a new ghostty — even though a working bm
# window already exists. Patch find_bm_ghostty_pid to query hyprctl for windows
# of class com.ko.bm directly, sidestepping the orphan trap. Also cleans up any
# orphan bm ghostty processes currently alive.
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

new_fn = r'''find_bm_ghostty_pid() {
  # om37: focus by class. Replaces the prior `pgrep -x bm-py | head -1`
  # + ancestry walk, which picked the OLDEST bm-py — on 3.7+ that often
  # pointed to an orphan ghostty whose window had already been closed.
  # focus_hyprland_window_by_pid would then return 1, and cmd_focus would
  # spawn a new ghostty even though a working bm window already existed.
  # Class-based lookup short-circuits the orphan trap: if a com.ko.bm
  # window exists, return its PID; otherwise fail and let cmd_focus spawn.
  command -v hyprctl >/dev/null 2>&1 || return 1
  local pid
  pid="$(hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c.get('class') == 'com.ko.bm':
        print(c.get('pid', ''))
        break
" 2>/dev/null)"
  [[ -n "$pid" && "$pid" != "0" ]] || return 1
  echo "$pid"
}'''

if 'om37: focus by class' in src:
    print("bm: focus fix already applied")
    sys.exit(0)

# Match the existing find_bm_ghostty_pid: function header through the next
# `^}` on its own line. Non-greedy so it stops at the function's closer.
pattern = re.compile(r'^find_bm_ghostty_pid\(\) \{[\s\S]*?^\}', re.M)
m = pattern.search(src)
if not m:
    print("bm: find_bm_ghostty_pid not found in expected shape, skipping")
    sys.exit(2)

src = src[:m.start()] + new_fn + src[m.end():]
with open(path, 'w') as f:
    f.write(src)
print("bm: focus fix applied (find_bm_ghostty_pid -> class lookup)")
PY

# Clean up orphan ghostty bm processes (alive but no hyprland window). One-shot:
# the focus fix prevents these from tricking Super+Alt+H, but it does NOT stop
# them from being created. Keep an eye out — if they keep accumulating, the
# close path needs investigation independently.
echo ""
echo "cleanup: orphan ghostty bm processes"

live_pids=""
if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  live_pids="$(hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class') == 'com.ko.bm':
        p = c.get('pid')
        if p: print(p)
" 2>/dev/null | sort -u)"
fi

mapfile -t all_bm < <(pgrep -af -- '--config-file=.*ghostty/bm\.conf' 2>/dev/null | awk '{print $1}')

orphans=()
for gpid in "${all_bm[@]}"; do
  if ! grep -qx "$gpid" <<< "$live_pids"; then
    orphans+=("$gpid")
  fi
done

if (( ${#orphans[@]} == 0 )); then
  echo "  no orphan ghostty processes"
else
  echo "  killing ${#orphans[@]} orphan ghostty PIDs: ${orphans[*]}"
  for o in "${orphans[@]}"; do
    kill -TERM "$o" 2>/dev/null || true
  done
  sleep 0.5
  for o in "${orphans[@]}"; do
    kill -KILL "$o" 2>/dev/null || true
  done
fi

# Also kill stale bm-py processes whose ghostty parent is gone. Textual
# swallows SIGHUP, so bm-py survives its terminal closing and gets
# reparented to systemd-user. These don't have a window and no Super+Alt+
# keybind reaches them — pure waste.
mapfile -t all_bmpy < <(pgrep -x bm-py 2>/dev/null)
zombies=()
for bp in "${all_bmpy[@]}"; do
  ppid="$(ps -o ppid= -p "$bp" 2>/dev/null | tr -d ' ')"
  pcomm="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ')"
  # parent is not ghostty (or parent is gone) → orphaned
  [[ "$pcomm" != "ghostty" ]] && zombies+=("$bp")
done

if (( ${#zombies[@]} == 0 )); then
  echo "  no zombie bm-py processes"
else
  echo "  killing ${#zombies[@]} zombie bm-py PIDs: ${zombies[*]}"
  for z in "${zombies[@]}"; do
    kill -TERM "$z" 2>/dev/null || true
  done
  sleep 0.5
  for z in "${zombies[@]}"; do
    kill -KILL "$z" 2>/dev/null || true
  done
fi
