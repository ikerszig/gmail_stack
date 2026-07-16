#!/bin/sh
# gmail_stack_monitor.sh
# Collects health metrics into a fast, world-readable status file that the
# Zabbix agent (running as the unprivileged `zabbix` user) can just cat/awk.
# Run from ROOT cron every ~15 min — it needs docker + root's borg ssh key.
#
# Deploy: /root/gmail_stack_monitor.sh   (chmod +x)
# Cron:   */15 * * * * /root/gmail_stack_monitor.sh >/dev/null 2>&1
set -u

STATUS_DIR="/var/lib/gmail_stack_monitor"
STATUS="$STATUS_DIR/status"
CACHE="$STATUS_DIR/borg_last_epoch"
BORGCHECK="$STATUS_DIR/borgcheck"
REPO="ssh://ikerszig@192.168.1.201/home/ikerszig/RaspiSystemBackups/gmail_stack_borg"

mkdir -p "$STATUS_DIR"
now=$(date +%s)

# --- container running state (1/0) ---
running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] && echo 1 || echo 0
}
sync_running=$(running gmail_stack_mbsync)
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

# --- mbsync (Gmail) sync heartbeat + recent failures ---
sync_age_min=$(sync_age gmail_stack_mbsync)
sync_fail=$(docker logs --tail 60 gmail_stack_mbsync 2>&1 | grep -c "sync failed" || true)

# --- vdirsyncer (Calendar) sync heartbeat + recent failures ---
vdirsyncer_age_min=$(sync_age gmail_stack_vdirsyncer)
vdirsyncer_fail=$(docker logs --tail 60 gmail_stack_vdirsyncer 2>&1 | grep -c "sync failed" || true)

# --- mailbox sizes (bytes) for trend graphs / sudden-drop alerting ---
maildir_bytes() {
  [ -d "$1" ] && du -sb "$1" 2>/dev/null | cut -f1 || echo 0
}
maildir_size_main=$(maildir_bytes "/srv/gmail_stack/data/maildir/ikerszig@gmail.com")
maildir_size_save=$(maildir_bytes "/srv/gmail_stack/data/maildir/ikerszig_save@ikermail.ddns.net")
[ -z "$maildir_size_main" ] && maildir_size_main=0
[ -z "$maildir_size_save" ] && maildir_size_save=0

# --- newest borg archive age (hours), cached so a transient borg/ssh
#     hiccup keeps the last-known-good value instead of a false -1 ---
export BORG_PASSPHRASE="$(cat /root/backup/.borg_passphrase 2>/dev/null || true)"
name=$(timeout 60 borg list "$REPO" --last 1 --short 2>/dev/null || true)
if [ -n "$name" ]; then
  dt=$(echo "$name" | sed -E 's/^gmail_stack-([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$/\1 \2:\3:\4/')
  be=$(date -d "$dt" +%s 2>/dev/null || true)
  [ -n "$be" ] && echo "$be" > "$CACHE"
fi
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
  echo "sync_running $sync_running"
  echo "dovecot_running $dovecot_running"
  echo "vdirsyncer_running $vdirsyncer_running"
  echo "sync_age_min $sync_age_min"
  echo "sync_fail $sync_fail"
  echo "vdirsyncer_age_min $vdirsyncer_age_min"
  echo "vdirsyncer_fail $vdirsyncer_fail"
  echo "maildir_size_main $maildir_size_main"
  echo "maildir_size_save $maildir_size_save"
  echo "borg_age_hours $borg_age_hours"
  echo "borg_check_result ${borg_check_result:--1}"
  echo "borg_check_age_days ${borg_check_age_days:--1}"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
chmod 644 "$STATUS"
