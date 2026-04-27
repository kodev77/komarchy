#!/usr/bin/env bash
# retro: install per-user linapple config presets and `apple2-run` wrapper
# so any apple ii project can launch a disk without copying configs locally.
# Configs land in ~/.config/linapple/, wrapper in ~/.local/bin/. Default
# scale is 2.0x; presets at 1.0/2.0/2.5/3.0/3.5x are available via the
# wrapper's positional scale arg.
set -euo pipefail

PKG_CONF="/usr/local/etc/linapple/linapple.conf"
USER_CONF_DIR="$HOME/.config/linapple"
USER_BIN_DIR="$HOME/.local/bin"
WRAPPER="$USER_BIN_DIR/apple2-run"
DEFAULT_FACTOR="2.0"

# Computer Emulation: 0=Apple][  1=Apple][+  2=//e  3=//e enhanced
DEFAULT_MACHINE="1"

# Video Emulation: 1=Color Standard, 2=Color Text, 3=Color TV, 4=Color Half-Shift,
#                  5=Mono Amber, 6=Mono Green (phosphor), 7=Mono White
DEFAULT_VIDEO="1"

if [[ ! -f "$PKG_CONF" ]]; then
  echo "  linapple package config not found at $PKG_CONF"
  echo "  install linapple first (run 022-00119-lna-ins.sh)"
  exit 2
fi

mkdir -p "$USER_CONF_DIR" "$USER_BIN_DIR"

# Generate scale preset configs from the package default
for FACTOR in 1.0 2.0 2.5 3.0 3.5; do
  PRESET="$USER_CONF_DIR/linapple-${FACTOR}x.conf"
  if [[ ! -f "$PRESET" ]]; then
    cp "$PKG_CONF" "$PRESET"
    sed -i "s/^\tScreen factor = .*/\tScreen factor = ${FACTOR}/" "$PRESET"
    sed -i "s/^\tComputer Emulation = .*/\tComputer Emulation = ${DEFAULT_MACHINE}/" "$PRESET"
    sed -i "s/^\tVideo Emulation = .*/\tVideo Emulation = ${DEFAULT_VIDEO}/" "$PRESET"
    echo "  wrote $PRESET (Screen factor = $FACTOR, Machine = $DEFAULT_MACHINE, Video = $DEFAULT_VIDEO)"
  else
    echo "  exists, skipped: $PRESET"
  fi
done

# Default conf is a copy of the chosen-factor preset
DEFAULT_CONF="$USER_CONF_DIR/linapple.conf"
if [[ ! -f "$DEFAULT_CONF" ]]; then
  cp "$USER_CONF_DIR/linapple-${DEFAULT_FACTOR}x.conf" "$DEFAULT_CONF"
  echo "  wrote $DEFAULT_CONF (default = ${DEFAULT_FACTOR}x)"
else
  echo "  exists, skipped: $DEFAULT_CONF"
fi

# Install the apple2-run wrapper
if [[ ! -f "$WRAPPER" ]]; then
  cat > "$WRAPPER" <<'WRAPPEREOF'
#!/usr/bin/env bash
# apple2-run: launch linapple from any directory using the user-level
# config presets in ~/.config/linapple/.
#
# Usage:
#   apple2-run                    - boot first *.dsk in cwd, default scale
#   apple2-run disk.dsk           - boot named disk, default scale
#   apple2-run disk.dsk 3         - boot named disk at 3.0x
#   apple2-run 3                  - auto-find disk, 3.0x
#   apple2-run disk.dsk 2.5 -f    - disk + 2.5x + linapple's own fullscreen
#
# Disk-image extensions auto-detected: dsk, do, po, nib, 2mg, hdv

set -euo pipefail

CONF_DIR="$HOME/.config/linapple"
DEFAULT_CONF="$CONF_DIR/linapple.conf"

DISK=""
SCALE=""

# arg1 may be a disk path
if [[ "${1:-}" =~ \.(dsk|do|po|nib|2mg|hdv)$ ]]; then
  DISK="$1"
  shift
fi

# next arg may be a scale number
if [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  SCALE="$1"
  shift
fi

# auto-find a disk if none was specified
if [[ -z "$DISK" ]]; then
  DISK=$(find . -maxdepth 1 -type f \
    \( -iname "*.dsk" -o -iname "*.do" -o -iname "*.po" \
       -o -iname "*.nib" -o -iname "*.2mg" -o -iname "*.hdv" \) \
    2>/dev/null | sort | head -1)
  if [[ -z "$DISK" ]]; then
    echo "apple2-run: no disk image in cwd (.dsk/.do/.po/.nib/.2mg/.hdv)" >&2
    echo "usage: apple2-run [disk] [scale] [linapple-flags...]" >&2
    exit 1
  fi
fi

# choose config
CONF="$DEFAULT_CONF"
if [[ -n "$SCALE" ]]; then
  REQ="$SCALE"
  [[ "$SCALE" != *.* ]] && REQ="${SCALE}.0"
  PRESET="$CONF_DIR/linapple-${REQ}x.conf"
  if [[ -f "$PRESET" ]]; then
    CONF="$PRESET"
  else
    echo "apple2-run: no preset for scale ${SCALE}, using default" >&2
  fi
fi

exec linapple --conf "$CONF" -b --d1 "$DISK" "$@"
WRAPPEREOF
  chmod +x "$WRAPPER"
  echo "  wrote $WRAPPER"
else
  echo "  exists, skipped: $WRAPPER"
fi

# verify the wrapper resolves on PATH
if ! command -v apple2-run &>/dev/null; then
  echo ""
  echo "  warning: $USER_BIN_DIR is not on PATH"
  echo "  add to your shell init: export PATH=\"\$HOME/.local/bin:\$PATH\""
  exit 1
fi

echo ""
echo "use: apple2-run                    (auto-find *.dsk in cwd)"
echo "     apple2-run disk.dsk           (boot named disk)"
echo "     apple2-run disk.dsk 3         (3.0x scale)"
echo "     apple2-run 3                  (auto-find disk + 3.0x)"
echo "     apple2-run -h                 (linapple help)"
