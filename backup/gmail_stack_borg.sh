#!/bin/sh
# ==========================================
# gmail_stack Borg Backup - DATA + STACK CONFIG
# Compatible with sh (dash). Minta: syncthing_borg.sh
# Append-only, restricted key (esgpi-borg host alias) - CSAK create/check,
# a prune az esgpi-n fut helyben (lasd /home/ikerszig/borg_prune_all.sh).
# ==========================================

BASE_LOCAL_BACKUP_DIR="$1"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

REMOTE_USER="ikerszig"
REMOTE_HOST="esgpi-borg"
BASE_REMOTE_BACKUP_DIR="/home/ikerszig/RaspiSystemBackups/gmail_stack_borg"

REPO="ssh://${REMOTE_USER}@${REMOTE_HOST}${BASE_REMOTE_BACKUP_DIR}"

export BORG_PASSPHRASE="$(cat /root/backup/.borg_passphrase)"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

GMAIL_STACK_DATA="/srv/gmail_stack/data"
GMAIL_STACK_CONFIG="/opt/stacks/gmail_stack"

ERROR_COUNT=0
record_error() { ERROR_COUNT=$((ERROR_COUNT + 1)); echo "ERROR: $1"; }

ensure_repo() {
    echo "[INFO] Checking Borg repository..."
    borg info "$REPO" > /dev/null 2>&1 || record_error "Borg repository not reachable"
}

check_repo_health() {
    echo "[INFO] Checking Borg repository health..."
    borg check "$REPO" || record_error "Borg repository check failed"
}

backup_gmail_stack() {
    echo "[INFO] Backing up gmail_stack data + config ($GMAIL_STACK_DATA, $GMAIL_STACK_CONFIG)..."
    borg create --compression lz4         "$REPO::gmail_stack-$TIMESTAMP" "$GMAIL_STACK_DATA" "$GMAIL_STACK_CONFIG"         || record_error "Failed to backup gmail_stack"
}

echo "=== gmail_stack Borg Backup Started: $TIMESTAMP ==="
ensure_repo
check_repo_health
backup_gmail_stack
echo "=== gmail_stack Borg Backup Finished: $TIMESTAMP ==="

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "SUMMARY: Errors occurred ($ERROR_COUNT)"; exit 1
else
    echo "SUMMARY: Backup completed successfully"; exit 0
fi
