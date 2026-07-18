# gmail_stack monitoring (Zabbix)

"Root cron collects → Zabbix agent reads" pattern. A privileged cron writes
fast, world-readable status files; the `zabbix` user only cats/awks them,
so no docker/root/borg access is needed at poll time.

Two independent status files, two independent scripts:

- `/var/lib/gmail_stack_monitor/status` — written by `gmail_stack_monitor.sh`:
  Dovecot, Calendar sync (vdirsyncer), mailbox sizes, Borg backup health.
- `/var/lib/gmail_stack_monitor/sync_status` — written by `gmail_stack_sync.sh`:
  the Gmail mbsync sync+prune run. This script is the **sole caller of
  mbsync** in the stack (the `gmail_stack_mbsync` container's own
  entrypoint.sh loop is deliberately disabled — see below), so it reports
  its own outcome directly instead of anything re-deriving it from
  container logs afterward.

## Deploy (raspi)

```sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_monitor.sh     /root/gmail_stack_monitor.sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_sync.sh        /root/gmail_stack_sync.sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_borg_check.sh  /root/gmail_stack_borg_check.sh
sudo chmod +x /root/gmail_stack_monitor.sh /root/gmail_stack_sync.sh /root/gmail_stack_borg_check.sh
sudo cp /opt/stacks/gmail_stack/monitoring/zabbix_gmail_stack.conf /etc/zabbix/zabbix_agent2.d/gmail_stack.conf

# first run + agent reload
sudo /root/gmail_stack_monitor.sh
sudo /root/gmail_stack_sync.sh
sudo systemctl restart zabbix-agent2
```

Root crontab:

```
*/15 * * * * /root/gmail_stack_monitor.sh >/dev/null 2>&1
*/15 * * * * /root/gmail_stack_sync.sh >/dev/null 2>&1
30 8 * * 0   /root/gmail_stack_borg_check.sh >/dev/null 2>&1
```

(The two `*/15` entries are safe on the same minute — they touch
completely separate status files and neither one calls `docker exec` on
the same container the other reads, so they never contend for anything.)

Test locally (agent-side):

```sh
for k in sync_running dovecot_running vdirsyncer_running sync_age_min sync_fail \
         vdirsyncer_age_min vdirsyncer_fail borg_age_hours borg_check borg_check_age \
         prune_last_run prune_last_removed prune_last_errors; do
  printf '%s = ' "$k"; sudo -u zabbix zabbix_agent2 -t "gmail_stack.$k" 2>/dev/null | sed -E 's/.*\|(.*)\]/\1/'
done
```

## Gmail sync + orphan pruning (`gmail_stack_sync.sh`)

`mbsync` mirrors Gmail one-directionally (`Sync Pull` + `Remove Near`). When
a mailbox disappears or is renamed on the Gmail side (e.g. deleting a
folder in a client — Gmail actually moves it under `[Gmail]/Trash/<name>`
rather than destroying it outright), `mbsync` will only auto-remove the
stale local mirror copy if it's empty. A non-empty stale copy just
produces a harmless `Warning: ... is not empty` and the run still exits 0
— the sync itself never gets stuck, but the local mirror silently drifts
from Gmail's real structure over time.

`gmail_stack_sync.sh` closes that gap in one pass:

1. Runs `mbsync -a -V` against the (idled — see below) `gmail_stack_mbsync`
   container.
2. Parses the output for orphan warnings.
3. For each one, independently re-verifies via a direct IMAP `SELECT` that
   the far side genuinely has no such box (belt-and-braces, not just
   trusting mbsync's own message).
4. Removes the confirmed-orphaned local copy. Safe because content isn't
   actually at risk here — the same maildir is Borg-backed nightly
   (`gmail_stack_borg`), so a pruned local mirror folder is never the only
   copy.
5. Re-syncs once more so anything that moved lands cleanly at its new path
   in the same run.
6. Writes `sync_status` (`sync_running`, `sync_last_run`, `sync_last_ok`,
   `prune_last_removed`, `prune_last_errors`) and logs everything to
   `/var/log/gmail_stack/sync.log` (self-trims to the last 2000 lines).

### Why the mbsync container just sleeps

`docker-compose.yml` overrides the `mbsync-sync` service's entrypoint to
`sleep infinity` — its own built-in loop (`entrypoint.sh`, syncing every
`SYNC_INTERVAL_SECONDS`) is intentionally disabled. `gmail_stack_sync.sh`
(root cron, host side, via `docker exec`) is the only thing that ever
invokes `mbsync` now. Previously the container's internal loop and any
cron-driven pruning pass ran on independent, unsynchronized schedules —
never observed to corrupt anything (mbsync locks its own state), but two
sync attempts racing for the same lock files was unnecessary noise this
avoids outright. The container stays `Up`, `docker exec` still works
against it fine — only its own idle-loop entrypoint is gone.

## Zabbix items (create on the host in the Zabbix UI)

Type **Zabbix agent** (passive), numeric (unsigned/float), update interval 5m:

| Key | Meaning |
|---|---|
| `gmail_stack.sync_running` | mbsync container up (1/0) |
| `gmail_stack.dovecot_running` | Dovecot container up (1/0) |
| `gmail_stack.vdirsyncer_running` | vdirsyncer (Calendar) container up (1/0) |
| `gmail_stack.sync_age_min` | minutes since `gmail_stack_sync.sh` last ran |
| `gmail_stack.sync_fail` | 1 if the last sync run did not end clean, else 0 |
| `gmail_stack.vdirsyncer_age_min` | minutes since last vdirsyncer loop start |
| `gmail_stack.vdirsyncer_fail` | count of recent vdirsyncer "sync failed" log lines |
| `gmail_stack.borg_age_hours` | age of newest Borg archive (hours) |
| `gmail_stack.borg_check` | last integrity check: 0 ok / 1 fail / -1 never |
| `gmail_stack.borg_check_age` | days since last integrity check |
| `gmail_stack.prune_last_run` | unix epoch of the last sync+prune run |
| `gmail_stack.prune_last_removed` | orphaned mailboxes removed in the last run |
| `gmail_stack.prune_last_errors` | prune-step errors in the last run (IMAP re-check mismatch, post-prune resync failure) — 0 in normal operation, including whenever orphans were found and cleanly removed |

## Suggested triggers

- **Dovecot down** (HIGH): `last(/HOST/gmail_stack.dovecot_running)=0`
- **mbsync container down** (WARN): `last(/HOST/gmail_stack.sync_running)=0`
- **Sync stale** (WARN): `last(/HOST/gmail_stack.sync_age_min)>45`
  (cron runs every 15 min; >45 min = several missed runs)
- **Sync failing** (AVG): `last(/HOST/gmail_stack.sync_fail)=1`
  (the last run didn't end clean — check `/var/log/gmail_stack/sync.log`;
  likely a revoked App Password or a real network/IMAP problem)
- **Calendar sync down** (WARN): `last(/HOST/gmail_stack.vdirsyncer_running)=0`
- **Calendar sync stale** (WARN): `last(/HOST/gmail_stack.vdirsyncer_age_min)>90`
- **Calendar sync failing** (AVG): `last(/HOST/gmail_stack.vdirsyncer_fail)>2`
  (repeated failures — likely expired OAuth token)
- **Backup stale** (HIGH): `last(/HOST/gmail_stack.borg_age_hours)>26`
  (nightly backup at 22:00 → should always be <26h)
- **Borg integrity fail** (HIGH): `last(/HOST/gmail_stack.borg_check)=1`
- **Integrity check overdue** (INFO): `last(/HOST/gmail_stack.borg_check_age)>14`
- **Orphan prune failing** (WARN): `last(/HOST/gmail_stack.prune_last_errors)>0`
  (IMAP re-check disagreed with mbsync, or the post-prune resync itself
  failed — investigate `/var/log/gmail_stack/sync.log`; a normal "found
  and removed an orphan" run reports 0 errors)

Note: `-1` means "unknown/not yet collected" — account for it in triggers if
needed (e.g. `>90` won't fire on `-1`, which is fine; add `and <>-1` where a
`-1` could otherwise trip a comparison).
