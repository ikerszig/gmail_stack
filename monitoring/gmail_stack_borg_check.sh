#!/bin/sh
# gmail_stack_borg_check.sh
# Runs `borg check` (full integrity read of the repo — expensive) and records
# the result for Zabbix. Run WEEKLY from root cron, at a time away from the
# nightly backup (22:00) so they don't fight over the repo lock.
#
# Deploy: /root/gmail_stack_borg_check.sh   (chmod +x)
# Cron:   30 8 * * 0 /root/gmail_stack_borg_check.sh >/dev/null 2>&1   # Sun 08:30
set -u

STATUS_DIR="/var/lib/gmail_stack_monitor"
BORGCHECK="$STATUS_DIR/borgcheck"
REPO="ssh://ikerszig@192.168.1.201/home/ikerszig/RaspiSystemBackups/gmail_stack_borg"

mkdir -p "$STATUS_DIR"
export BORG_PASSPHRASE="$(cat /root/backup/.borg_passphrase 2>/dev/null || true)"
now=$(date +%s)

if timeout 7200 borg check "$REPO" >/tmp/gmail_stack_borgcheck.log 2>&1; then
  res=0
else
  res=1
fi

{
  echo "borg_check_result $res"
  echo "borg_check_epoch $now"
} > "$BORGCHECK.tmp" && mv "$BORGCHECK.tmp" "$BORGCHECK"
chmod 644 "$BORGCHECK"
