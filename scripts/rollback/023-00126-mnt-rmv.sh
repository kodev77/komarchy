#!/usr/bin/env bash
# bm-tool-om37: rollback - no-op; clears the state marker so 023-00126-mnt-rmv.sh
# can be re-run for retesting. The cleanup itself (removing v1/v2 monitor blocks
# and the lid-switch override) is intentionally not reversed - omarchy 3.7
# handles the eDP/lid behavior natively, so restoring those blocks would
# regress the system.
set -euo pipefail
echo "state marker will be cleared; re-run 023-00126-mnt-rmv.sh to retest"
