#!/bin/sh
# ==========================================
# gmail_stack Borg Backup - DATA + STACK CONFIG
# Compatible with sh (dash). Minta: syncthing_borg.sh
# ==========================================

BASE_LOCAL_BACKUP_DIR="$1"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

REMOTE_USER="ikerszig"
REMOTE_HOST="10.9.0.2"
BASE_REMOTE_BACKUP_DIR="/home/ikerszig/RaspiSystemBackups/gmail_stack_borg"

REPO="ssh://${REMOTE_USER}@${REMOTE_HOST}${BASE_REMOTE_BACKUP_DIR}"

export BORG_PASSPHRASE="$(cat /root/backup/.borg_passphrase)"

GMAIL_STACK_DATA="/srv/gmail_stack/data"
GMAIL_STACK_CONFIG="/opt/stacks/gmail_stack"

ERROR_COUNT=0
record_error() { ERROR_COUNT=$((ERROR_COUNT + 1)); echo "ERROR: $1"; }

ensure_repo() {
    echo "[INFO] Checking Borg repository..."
    if ! borg info "$REPO" > /dev/null 2>&1; then
        echo "[INFO] Repository does not exist. Creating..."
        ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${BASE_REMOTE_BACKUP_DIR}" \
            || record_error "Failed to create remote Borg directory"
        borg init --encryption=repokey "$REPO" \
            || record_error "Cannot initialize Borg repository"
    else
        echo "[INFO] Repository exists."
    fi
}

check_repo_health() {
    echo "[INFO] Checking Borg repository health..."
    borg check "$REPO" || record_error "Borg repository check failed"
}

prune_old_backups() {
    echo "[INFO] Pruning (keep-daily 7, keep-weekly 8, keep-monthly 24)..."
    borg prune -v --list "$REPO" --keep-daily 7 --keep-weekly 8 --keep-monthly 24 || record_error "Failed to prune old backups"
}

backup_gmail_stack() {
    echo "[INFO] Backing up gmail_stack data + config ($GMAIL_STACK_DATA, $GMAIL_STACK_CONFIG)..."
    borg create --compression lz4 \
        "$REPO::gmail_stack-$TIMESTAMP" "$GMAIL_STACK_DATA" "$GMAIL_STACK_CONFIG" \
        || record_error "Failed to backup gmail_stack"
}

echo "=== gmail_stack Borg Backup Started: $TIMESTAMP ==="
ensure_repo
check_repo_health
backup_gmail_stack
prune_old_backups
echo "=== gmail_stack Borg Backup Finished: $TIMESTAMP ==="

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "SUMMARY: Errors occurred ($ERROR_COUNT)"; exit 1
else
    echo "SUMMARY: Backup completed successfully"; exit 0
fi
