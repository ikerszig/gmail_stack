#!/bin/sh
# Copy to /root/backup/modules/gmail_stack_borg.sh on the raspi.
# Modeled on the existing syncthing_borg.sh module — same remote host,
# same retention policy, same shared passphrase file. Picked up
# automatically by the main system_backup.sh (globs modules/*.sh).

set -eu

BORG_REPO="ssh://ikerszig@192.168.1.201/home/ikerszig/RaspiSystemBackups/gmail_stack_borg"
export BORG_PASSPHRASE_FILE="/root/backup/.borg_passphrase"

# First run on a fresh remote host: borg init --encryption=repokey-blake2 "$BORG_REPO"

borg create \
    --stats --compression zstd \
    "$BORG_REPO::gmail_stack-{now:%Y-%m-%d_%H%M%S}" \
    /srv/gmail_stack/data \
    /opt/stacks/gmail_stack

borg prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    "$BORG_REPO"
