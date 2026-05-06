#!/usr/bin/env bash
# updates: unmute Realtek codec Master + Bass Speaker and persist via alsactl.
# On fresh installs the hardware Master sits muted at -65.25 dB even when
# PipeWire's soft-mixer reads 100% / unmuted — the soft layer sits above the
# gated codec control, so audio goes nowhere. Symptom: silent speakers despite
# a healthy audio stack (sink RUNNING, port=Speakers, firmware loaded).
# Persisting via alsactl ensures alsa-restore.service brings these up on
# every boot. Guarded to ASUS ROG only.
set -euo pipefail

SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
PRODUCT_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

if [[ "$SYS_VENDOR" != *ASUS* ]]; then
  echo "not an ASUS host, skipping"
  exit 2
fi
if [[ "$PRODUCT_FAMILY" != *ROG* && "$PRODUCT_NAME" != *ROG* ]]; then
  echo "not an ASUS ROG host, skipping"
  exit 2
fi

if ! command -v amixer &>/dev/null || ! command -v alsactl &>/dev/null; then
  echo "alsa-utils not installed (amixer/alsactl missing)"
  exit 2
fi

# locate the Intel PCH card (where ALC285 + CS35L41 live)
CARD_IDX=$(awk '$1 ~ /^[0-9]+$/ && /Intel PCH/ {print $1; exit}' /proc/asound/cards)
if [[ -z "${CARD_IDX:-}" ]]; then
  echo "could not find Intel PCH audio card in /proc/asound/cards"
  exit 2
fi
echo "found Intel PCH at card index $CARD_IDX"

echo "unmuting Master + Bass Speaker..."
amixer -c "$CARD_IDX" sset Master 100% unmute >/dev/null
amixer -c "$CARD_IDX" sset 'Bass Speaker' 100% unmute >/dev/null 2>&1 || \
  echo "  (no 'Bass Speaker' control on this card; skipping)"

echo "persisting ALSA state to /var/lib/alsa/asound.state..."
sudo alsactl store

echo ""
echo "test: speaker-test -t sine -f 440 -c 2 -l 1"
