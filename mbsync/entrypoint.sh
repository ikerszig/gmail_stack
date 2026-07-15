#!/bin/sh
set -eu

INTERVAL="${SYNC_INTERVAL_SECONDS:-900}"

while true; do
  echo "[mbsync] sync start: $(date -Iseconds)"
  mbsync -a || echo "[mbsync] sync failed, will retry in ${INTERVAL}s"
  sleep "$INTERVAL"
done
