#!/bin/sh
# gmail_stack_monitor.sh
# Collects health metrics into a fast, world-readable status file that the
# Zabbix agent (running as the unprivileged `zabbix` user) can just cat/awk.
# Run from ROOT cron every ~15 min — it needs docker. Borg archive freshness
# is no longer probed live here; gmail_stack_borg.sh (the nightly backup)
# writes it directly, see the borg_age_hours block below.
#
# Note: mbsync (Gmail) sync health lives in its own status file, written
# directly by gmail_stack_sync.sh (which owns the sync+prune run and knows
# its own outcome firsthand) — see /var/lib/gmail_stack_monitor/sync_status
# and the gmail_stack.sync_* / gmail_stack.prune_* UserParameters. This
# script only covers what it can observe independently: Dovecot, the
# Calendar sync (vdirsyncer), mailbox sizes, and Borg backup health.
#
# Deploy: /root/gmail_stack_monitor.sh   (chmod +x)
# Cron:   */15 * * * * /root/gmail_stack_monitor.sh >/dev/null 2>&1
set -u

STATUS_DIR="/var/lib/gmail_stack_monitor"
STATUS="$STATUS_DIR/status"
CACHE="$STATUS_DIR/borg_last_epoch"
BORGCHECK="$STATUS_DIR/borgcheck"

mkdir -p "$STATUS_DIR"
now=$(date +%s)

# --- container running state (1/0) ---
running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] && echo 1 || echo 0
}
dovecot_running=$(running gmail_stack_dovecot)
vdirsyncer_running=$(running gmail_stack_vdirsyncer)

# minutes since a container's last "sync start" loop heartbeat, from its logs
sync_age() {
  _l=$(docker logs --tail 400 "$1" 2>&1 | grep "sync start:" | tail -1 | sed -E 's/.*sync start: //')
  [ -z "$_l" ] && { echo -1; return; }
  _e=$(date -d "$_l" +%s 2>/dev/null || true)
  [ -z "$_e" ] && { echo -1; return; }
  echo $(( (now - _e) / 60 ))
}

# --- vdirsyncer (Calendar) sync heartbeat + consecutive-failure tracking ---
# vdirsyncer_fail is a persistent consecutive-failure counter, NOT a raw
# grep count over a log tail - a tail-based count kept showing old,
# already-resolved failures until they scrolled out of the window (seen
# 2026-07-23: OAuth token was fixed and syncs succeeded again, but the
# trigger stayed active for ~an hour because stale "sync failed" lines
# were still inside the last 60 log lines).
#
# Instead: each run looks only at the outcome of the most recently
# STARTED sync cycle. A cycle already accounted for (same start marker as
# last run) is left untouched; a newly-observed cycle increments the
# counter on failure or resets it to 0 on success.
vdirsyncer_age_min=$(sync_age gmail_stack_vdirsyncer)

VDIR_STATE="$STATUS_DIR/vdirsyncer_fail_state"
VDIR_LOGS=$(docker logs --tail 200 gmail_stack_vdirsyncer 2>&1)
last_start_line=$(echo "$VDIR_LOGS" | grep -n "sync start:" | tail -1 | cut -d: -f1)

prev_start_ts=""
prev_count=0
if [ -f "$VDIR_STATE" ]; then
  prev_start_ts=$(awk '/^last_start_ts /{print $2}' "$VDIR_STATE")
  prev_count=$(awk '/^fail_count /{print $2}' "$VDIR_STATE")
  [ -z "$prev_count" ] && prev_count=0
fi

if [ -n "$last_start_line" ]; then
  cur_start_ts=$(echo "$VDIR_LOGS" | sed -n "${last_start_line}p" | sed -E 's/.*sync start: //')
  if [ "$cur_start_ts" = "$prev_start_ts" ]; then
    vdirsyncer_fail=$prev_count
  else
    if echo "$VDIR_LOGS" | tail -n "+$last_start_line" | grep -q "sync failed"; then
      vdirsyncer_fail=$((prev_count + 1))
    else
      vdirsyncer_fail=0
    fi
    {
      echo "last_start_ts $cur_start_ts"
      echo "fail_count $vdirsyncer_fail"
    } > "$VDIR_STATE.tmp" && mv "$VDIR_STATE.tmp" "$VDIR_STATE"
  fi
else
  vdirsyncer_fail=$prev_count
fi

# --- mailbox sizes (bytes) for trend graphs / sudden-drop alerting ---
maildir_bytes() {
  [ -d "$1" ] && du -sb "$1" 2>/dev/null | cut -f1 || echo 0
}
maildir_size_main=$(maildir_bytes "/srv/gmail_stack/data/maildir/ikerszig@gmail.com")
maildir_size_save=$(maildir_bytes "/srv/gmail_stack/data/maildir/ikerszig_save@ikermail.ddns.net")
[ -z "$maildir_size_main" ] && maildir_size_main=0
[ -z "$maildir_size_save" ] && maildir_size_save=0

# --- newest borg archive age (hours) ---
# Event-driven, not polled: gmail_stack_borg.sh (the nightly backup itself,
# 22:00) writes $CACHE the moment a backup succeeds - it's the one that
# actually knows the outcome firsthand. Backups only happen once a day, so
# probing Borg over SSH every ~15 min here just to check for a once-a-day
# event was 96 needless esgpi connections for 1 real change (fixed
# 2026-07-24, see osszefoglalo.md 2.9).
borg_age_hours=-1
if [ -f "$CACHE" ]; then
  be=$(cat "$CACHE")
  borg_age_hours=$(( (now - be) / 3600 ))
fi

# --- weekly borg check result/age (written by gmail_stack_borg_check.sh) ---
borg_check_result=-1
borg_check_age_days=-1
if [ -f "$BORGCHECK" ]; then
  borg_check_result=$(awk '/^borg_check_result /{print $2}' "$BORGCHECK")
  bce=$(awk '/^borg_check_epoch /{print $2}' "$BORGCHECK")
  [ -n "$bce" ] && borg_check_age_days=$(( (now - bce) / 86400 ))
fi

# --- atomic write ---
{
  echo "updated $now"
  echo "dovecot_running $dovecot_running"
  echo "vdirsyncer_running $vdirsyncer_running"
  echo "vdirsyncer_age_min $vdirsyncer_age_min"
  echo "vdirsyncer_fail $vdirsyncer_fail"
  echo "maildir_size_main $maildir_size_main"
  echo "maildir_size_save $maildir_size_save"
  echo "borg_age_hours $borg_age_hours"
  echo "borg_check_result ${borg_check_result:--1}"
  echo "borg_check_age_days ${borg_check_age_days:--1}"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
chmod 644 "$STATUS"
