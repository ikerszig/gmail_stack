#!/bin/sh
# ==========================================
# gmail_stack docker config backup - lokalis tar
# Compatible with sh (dash). Minta: syncthing.sh
# A fo script (system_backup.sh) rsync-eli a remote-ra es retentionozi (GFS).
# A tenyleges ADATOK (maildir, radicale, roundcube-db) a gmail_stack_borg.sh-ban,
# Borg-repoba mennek — ez a modul CSAK a stack docker/config allapotat menti.
# ==========================================

BASE_LOCAL_BACKUP_DIR="$1"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

GMAIL_STACK_BACKUP_DIR="$BASE_LOCAL_BACKUP_DIR/gmail_stack"
GMAIL_STACK="/opt/stacks/gmail_stack"

ERROR_COUNT=0
record_error() { ERROR_COUNT=$((ERROR_COUNT + 1)); echo "ERROR: $1"; }

echo "==== gmail_stack config backup $TIMESTAMP ===="
mkdir -p "$GMAIL_STACK_BACKUP_DIR" || record_error "Failed to create backup directory"

# Docker stack + osszes config: compose, Dockerfile-ok, apache/nftables/monitoring
# sablonok, ES a kitoltott secretek (dovecot passwd, radicale users, .mbsyncrc,
# vdirsyncer config + google_token.json) — ezek kellenek a teljes visszaallitashoz.
# Kihagyva: .git (a kod GitHubon van), vdirsyncer status-cache (ujraepitheto).
if tar -czf "$GMAIL_STACK_BACKUP_DIR/gmail_stack_config_$TIMESTAMP.tar.gz" \
    --exclude="*/.git" \
    --exclude="*/vdirsyncer/conf/status" \
    -C / opt/stacks/gmail_stack; then
    echo "[INFO] gmail_stack config backup completed"
else
    record_error "Failed to backup gmail_stack config"
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "SUMMARY: Errors occurred ($ERROR_COUNT)"; exit 1
else
    echo "SUMMARY: Backup completed successfully"; exit 0
fi
