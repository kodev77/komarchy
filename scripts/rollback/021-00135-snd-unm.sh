#!/usr/bin/env bash
# updates: rollback codec unmute — no-op. ALSA mixer state is runtime + state
# file; this rollback intentionally does NOT re-mute (that would silently
# break audio for the user). To undo manually:
#   amixer -c <N> sset Master mute && sudo alsactl store
set -euo pipefail
echo "no-op (audio settings left as-is); state marker will be cleared"
