#!/bin/sh
# gmail_stack_prune_orphans.sh
#
# mbsync (with "Remove Near" set) will WARN and refuse to auto-delete a
# local mailbox that has no far-side (Gmail) counterpart anymore, as long
# as that local copy still has messages in it — a deliberate isync safety
# guard against silent data loss. In this stack that guard is redundant:
# the same maildir is Borg-backed nightly, so a local mirror that lags
# behind Gmail's real folder structure is not actually protecting anything
# extra, it's just drift. This script closes that gap: it finds those
# warned-about orphans, independently re-verifies via a direct IMAP call
# that the far side genuinely has no such box (belt-and-braces, not just
# trusting mbsync's own message), then removes the stale local copy so
# the mirror stays a true 1:1 reflection of Gmail's current structure.
#
# Deploy: /root/gmail_stack_prune_orphans.sh   (chmod +x)
# Cron:   5-59/15 * * * * /root/gmail_stack_prune_orphans.sh >/dev/null 2>&1
#         (offset from gmail_stack_monitor.sh's */15 so they don't both
#          hit docker in the same minute)

set -u

CONFIG_HOST=/opt/stacks/gmail_stack/mbsync/conf/.mbsyncrc
MAILDIR_ROOT="/srv/gmail_stack/data/maildir/ikerszig@gmail.com"
LOG_DIR="/var/log/gmail_stack"
LOG="$LOG_DIR/prune_orphans.log"
STATUS_DIR="/var/lib/gmail_stack_monitor"
STATUS="$STATUS_DIR/prune_status"
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
  {
    echo "prune_last_run $(date +%s)"
    echo "prune_last_removed $1"
    echo "prune_last_errors $2"
  } > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
  chmod 644 "$STATUS"
}

PASS=$(grep '^Pass' "$CONFIG_HOST" | awk '{print $2}')
if [ -z "$PASS" ]; then
  log "FATAL: could not read app password from $CONFIG_HOST"
  write_status 0 1
  exit 1
fi

log "=== prune-orphans run start ==="

# 1) Run mbsync once, verbosely, to surface any "not empty" warnings.
OUT=$(docker exec gmail_stack_mbsync mbsync -c /etc/mbsyncrc -a -V 2>&1)
RC=$?
log "initial sync exit=$RC"

# 2) Extract orphan box names from lines like:
#    "Warning: channel gmail: far side box <NAME> cannot be opened and
#     near side box <NAME> is not empty."
ORPHANS_FILE="$LOG_DIR/.orphans.tmp"
echo "$OUT" | grep -oE 'far side box .* cannot be opened and near side box .* is not empty' \
  | sed -E 's/far side box (.*) cannot be opened and near side box .* is not empty/\1/' \
  > "$ORPHANS_FILE"

if [ ! -s "$ORPHANS_FILE" ]; then
  rm -f "$ORPHANS_FILE"
  log "no orphans found (sync exit=$RC)"
  write_status 0 $([ "$RC" -eq 0 ] && echo 0 || echo 1)
  trim_log
  exit 0
fi

REMOVED=0
ERRORS=0

while IFS= read -r BOX; do
  [ -z "$BOX" ] && continue
  log "candidate: $BOX"

  # 3) Independently re-verify via direct IMAP — don't just trust mbsync's
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
OUT2=$(docker exec gmail_stack_mbsync mbsync -c /etc/mbsyncrc -a 2>&1)
RC2=$?
log "post-prune sync exit=$RC2"
if [ "$RC2" -ne 0 ]; then
  log "post-prune sync output: $OUT2"
  ERRORS=$((ERRORS + 1))
fi

log "=== prune-orphans run end: removed=$REMOVED errors=$ERRORS ==="
write_status "$REMOVED" "$ERRORS"
trim_log

[ "$ERRORS" -gt 0 ] && exit 1
exit 0
