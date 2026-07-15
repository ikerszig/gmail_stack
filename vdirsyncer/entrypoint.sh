#!/bin/sh
set -eu

INTERVAL="${SYNC_INTERVAL_SECONDS:-900}"

if [ ! -f /root/.vdirsyncer/google_token.json ]; then
  echo "[vdirsyncer] no google_token.json found yet."
  echo "[vdirsyncer] run the one-time interactive OAuth step first (see README.md)."
  echo "[vdirsyncer] sleeping so the container doesn't crash-loop..."
  sleep infinity
fi

vdirsyncer discover google_calendar || true

while true; do
  echo "[vdirsyncer] sync start: $(date -Iseconds)"
  vdirsyncer sync || echo "[vdirsyncer] sync failed, will retry in ${INTERVAL}s"
  sleep "$INTERVAL"
done
