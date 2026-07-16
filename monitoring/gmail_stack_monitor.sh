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

# --- minutes since last mbsync "sync start" (loop heartbeat) ---
sync_age_min=-1
last=$(docker logs --tail 400 gmail_stack_mbsync 2>&1 | grep "sync start:" | tail -1 | sed -E 's/.*sync start: //')
if [ -n "$last" ]; then
  e=$(date -d "$last" +%s 2>/dev/null || true)
  [ -n "$e" ] && sync_age_min=$(( (now - e) / 60 ))
fi

# --- recent sync failures (App Password revoked, network, etc.) ---
sync_fail=$(docker logs --tail 60 gmail_stack_mbsync 2>&1 | grep -c "sync failed" || true)

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
  echo "sync_age_min $sync_age_min"
  echo "sync_fail $sync_fail"
  echo "borg_age_hours $borg_age_hours"
  echo "borg_check_result ${borg_check_result:--1}"
  echo "borg_check_age_days ${borg_check_age_days:--1}"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
chmod 644 "$STATUS"
