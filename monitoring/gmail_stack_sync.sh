#!/bin/sh
# gmail_stack_sync.sh
#
# Sole trigger for Gmail mbsync in this stack: runs the sync, then prunes
# any orphaned local mailbox mirrors mbsync warned about but wouldn't
# auto-remove (non-empty "Remove Near" targets), then re-syncs once more.
# Writes its own status file for Zabbix (see zabbix_gmail_stack.conf) so
# there's a single, direct source of truth instead of parsing container
# logs after the fact.
#
# The mbsync container's own internal loop is disabled (docker-compose.yml
# overrides its command to idle) specifically so this script is the ONLY
# thing that ever invokes mbsync - avoids any chance of two mbsync runs
# overlapping and contending for its per-mailbox lock files.
#
# Why prune non-empty orphans at all: mbsync (Sync Pull + Remove Near)
# mirrors Gmail one-directionally, but refuses to auto-delete a stale local
# mailbox copy that still has messages in it - a sensible default in
# general, but redundant here since the same maildir is Borg-backed
# nightly. A non-empty orphan just produces a harmless warning and mbsync
# still exits 0, so the sync itself never gets stuck - this script closes
# the remaining drift between the local mirror and Gmail's real structure.
#
# Deploy: /root/gmail_stack_sync.sh   (chmod +x)
# Cron:   */15 * * * * /root/gmail_stack_sync.sh >/dev/null 2>&1

set -u

CONTAINER=gmail_stack_mbsync
CONFIG_HOST=/opt/stacks/gmail_stack/mbsync/conf/.mbsyncrc
MAILDIR_ROOT="/srv/gmail_stack/data/maildir/ikerszig@gmail.com"
LOG_DIR="/var/log/gmail_stack"
LOG="$LOG_DIR/sync.log"
STATUS_DIR="/var/lib/gmail_stack_monitor"
STATUS="$STATUS_DIR/sync_status"
MAX_LOG_LINES=2000

mkdir -p "$LOG_DIR" "$STATUS_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(ts)" "$1" >> "$LOG"; }

trim_log() {
  [ -f "$LOG" ] || return 0
  lines=$(wc -l < "$LOG")
  if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

write_status() {
  # $1=sync_running $2=sync_last_ok $3=prune_removed $4=prune_errors
  {
    echo "sync_running $1"
    echo "sync_last_run $(date +%s)"
    echo "sync_last_ok $2"
    echo "prune_last_removed $3"
    echo "prune_last_errors $4"
  } > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
  chmod 644 "$STATUS"
}

log "=== sync run start ==="

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)
if [ "$RUNNING" != "true" ]; then
  log "FATAL: container $CONTAINER is not running"
  write_status 0 0 0 1
  trim_log
  exit 1
fi

PASS=$(grep '^Pass' "$CONFIG_HOST" | awk '{print $2}')
if [ -z "$PASS" ]; then
  log "FATAL: could not read app password from $CONFIG_HOST"
  write_status 1 0 0 1
  trim_log
  exit 1
fi

# 1) Run mbsync verbosely so we can see any "not empty" orphan warnings.
OUT=$(docker exec "$CONTAINER" mbsync -c /etc/mbsyncrc -a -V 2>&1)
RC=$?
log "initial sync exit=$RC"
if [ "$RC" -ne 0 ]; then
  log "initial sync output: $OUT"
fi

# 2) Extract orphan box names from lines like:
#    "Warning: channel gmail: far side box <NAME> cannot be opened and
#     near side box <NAME> is not empty."
ORPHANS_FILE="$LOG_DIR/.orphans.tmp"
echo "$OUT" | grep -oE 'far side box .* cannot be opened and near side box .* is not empty' \
  | sed -E 's/far side box (.*) cannot be opened and near side box .* is not empty/\1/' \
  > "$ORPHANS_FILE"

if [ ! -s "$ORPHANS_FILE" ]; then
  rm -f "$ORPHANS_FILE"
  log "no orphans found"
  log "=== sync run end: ok=$([ "$RC" -eq 0 ] && echo 1 || echo 0) removed=0 errors=$([ "$RC" -eq 0 ] && echo 0 || echo 1) ==="
  write_status 1 "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" 0 "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
  trim_log
  [ "$RC" -eq 0 ] && exit 0 || exit 1
fi

REMOVED=0
ERRORS=0

while IFS= read -r BOX; do
  [ -z "$BOX" ] && continue
  log "candidate: $BOX"

  # 3) Independently re-verify via direct IMAP - don't just trust mbsync's
  #    own message. Only proceed if the far side genuinely has no such box.
  REMOTE_CHECK=$(python3 -c "
import imaplib
try:
    m = imaplib.IMAP4_SSL('imap.gmail.com')
    m.login('ikerszig@gmail.com', '$PASS')
    typ, _ = m.select('$BOX', readonly=True)
    m.logout()
    print(typ)
except Exception as e:
    print('IMAPERR', e)
" 2>/dev/null)

  case "$REMOTE_CHECK" in
    OK)
      log "SKIP $BOX: far side box actually exists on re-check (not removing)"
      ERRORS=$((ERRORS + 1))
      continue
      ;;
    NO)
      : # confirmed gone on far side, proceed
      ;;
    *)
      log "SKIP $BOX: IMAP re-check inconclusive ($REMOTE_CHECK), not removing"
      ERRORS=$((ERRORS + 1))
      continue
      ;;
  esac

  LOCAL_DIR="$MAILDIR_ROOT/$BOX"
  if [ ! -d "$LOCAL_DIR" ]; then
    log "SKIP $BOX: local dir not found at $LOCAL_DIR"
    continue
  fi

  COUNT=$(find "$LOCAL_DIR/cur" "$LOCAL_DIR/new" -type f 2>/dev/null | wc -l)
  rm -rf "$LOCAL_DIR"
  log "REMOVED $BOX ($COUNT local messages; content remains in nightly Borg backup)"
  REMOVED=$((REMOVED + 1))
done < "$ORPHANS_FILE"
rm -f "$ORPHANS_FILE"

# 4) Re-sync so anything that moved lands cleanly at its new path in the
#    same run, and to confirm the removal actually resolved the warning.
OUT2=$(docker exec "$CONTAINER" mbsync -c /etc/mbsyncrc -a 2>&1)
RC2=$?
log "post-prune sync exit=$RC2"
if [ "$RC2" -ne 0 ]; then
  log "post-prune sync output: $OUT2"
  ERRORS=$((ERRORS + 1))
fi

SYNC_OK=$([ "$RC2" -eq 0 ] && echo 1 || echo 0)
log "=== sync run end: ok=$SYNC_OK removed=$REMOVED errors=$ERRORS ==="
write_status 1 "$SYNC_OK" "$REMOVED" "$ERRORS"
trim_log

[ "$SYNC_OK" -eq 1 ] && [ "$ERRORS" -eq 0 ] && exit 0
exit 1
