# gmail_stack monitoring (Zabbix)

"Root cron collects → Zabbix agent reads" pattern. A privileged cron writes a
fast, world-readable status file; the `zabbix` user only cats/awks it, so no
docker/root/borg access is needed at poll time.

## Deploy (raspi)

```sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_monitor.sh        /root/gmail_stack_monitor.sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_borg_check.sh     /root/gmail_stack_borg_check.sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_prune_orphans.sh  /root/gmail_stack_prune_orphans.sh
sudo chmod +x /root/gmail_stack_monitor.sh /root/gmail_stack_borg_check.sh /root/gmail_stack_prune_orphans.sh
sudo cp /opt/stacks/gmail_stack/monitoring/zabbix_gmail_stack.conf /etc/zabbix/zabbix_agent2.d/gmail_stack.conf

# first run + agent reload
sudo /root/gmail_stack_monitor.sh
sudo systemctl restart zabbix-agent2
```

Root crontab:

```
*/15 * * * *    /root/gmail_stack_monitor.sh >/dev/null 2>&1
5-59/15 * * * * /root/gmail_stack_prune_orphans.sh >/dev/null 2>&1
30 8 * * 0      /root/gmail_stack_borg_check.sh >/dev/null 2>&1
```

Test locally (agent-side):

```sh
for k in sync_running dovecot_running sync_age_min sync_fail borg_age_hours borg_check borg_check_age \
         prune_last_run prune_last_removed prune_last_errors; do
  printf '%s = ' "$k"; sudo -u zabbix zabbix_agent2 -t "gmail_stack.$k" 2>/dev/null | sed -E 's/.*\|(.*)\]/\1/'
done
```

## Orphan pruning (`gmail_stack_prune_orphans.sh`)

`mbsync` mirrors Gmail one-directionally (`Sync Pull` + `Remove Near`). When a
mailbox disappears or is renamed on the Gmail side (e.g. deleting a folder
in a client — Gmail actually moves it under `[Gmail]/Trash/<name>` rather
than destroying it outright), `mbsync` will only auto-remove the stale
local mirror copy if it's empty. A non-empty stale copy just produces a
harmless `Warning: ... is not empty` and the run still exits 0 — the sync
itself never gets stuck, but the local mirror silently drifts from Gmail's
real structure over time.

`gmail_stack_prune_orphans.sh` closes that gap: every run it re-syncs,
parses the warning for orphaned box names, independently re-verifies via a
direct IMAP `SELECT` that the far side really has no such box (not just
trusting mbsync's message), then removes the stale local copy and re-syncs
once more. Safe because content isn't actually at risk here — the same
maildir is Borg-backed nightly (`gmail_stack_borg`), so a pruned local
mirror folder is never the only copy.

Logs to `/var/log/gmail_stack/prune_orphans.log` (self-trims to the last
2000 lines) and writes `/var/lib/gmail_stack_monitor/prune_status`, which
the Zabbix items below read from — same "root cron writes, zabbix user
just reads" pattern as the rest of this monitoring.

## Zabbix items (create on the host in the Zabbix UI)

Type **Zabbix agent** (passive), numeric (unsigned/float), update interval 5m:

| Key | Meaning |
|---|---|
| `gmail_stack.sync_running` | mbsync container up (1/0) |
| `gmail_stack.dovecot_running` | Dovecot container up (1/0) |
| `gmail_stack.vdirsyncer_running` | vdirsyncer (Calendar) container up (1/0) |
| `gmail_stack.sync_age_min` | minutes since last mbsync loop start |
| `gmail_stack.sync_fail` | count of recent mbsync "sync failed" log lines |
| `gmail_stack.vdirsyncer_age_min` | minutes since last vdirsyncer loop start |
| `gmail_stack.vdirsyncer_fail` | count of recent vdirsyncer "sync failed" log lines |
| `gmail_stack.borg_age_hours` | age of newest Borg archive (hours) |
| `gmail_stack.borg_check` | last integrity check: 0 ok / 1 fail / -1 never |
| `gmail_stack.borg_check_age` | days since last integrity check |
| `gmail_stack.prune_last_run` | unix epoch of last orphan-prune run |
| `gmail_stack.prune_last_removed` | orphaned mailboxes removed in the last run |
| `gmail_stack.prune_last_errors` | prune-script errors in the last run (IMAP re-check mismatch, post-prune resync failure) — 0 in normal operation, including whenever orphans were found and cleanly removed |

## Suggested triggers

- **Dovecot down** (HIGH): `last(/HOST/gmail_stack.dovecot_running)=0`
- **mbsync down** (WARN): `last(/HOST/gmail_stack.sync_running)=0`
- **Sync stale** (WARN): `last(/HOST/gmail_stack.sync_age_min)>90`
  (loop runs ~every 30 min; >90 min = stuck/dead)
- **Sync failing** (AVG): `last(/HOST/gmail_stack.sync_fail)>2`
  (repeated failures — likely revoked App Password)
- **Calendar sync down** (WARN): `last(/HOST/gmail_stack.vdirsyncer_running)=0`
- **Calendar sync stale** (WARN): `last(/HOST/gmail_stack.vdirsyncer_age_min)>90`
- **Calendar sync failing** (AVG): `last(/HOST/gmail_stack.vdirsyncer_fail)>2`
  (repeated failures — likely expired OAuth token)
- **Backup stale** (HIGH): `last(/HOST/gmail_stack.borg_age_hours)>26`
  (nightly backup at 22:00 → should always be <26h)
- **Borg integrity fail** (HIGH): `last(/HOST/gmail_stack.borg_check)=1`
- **Integrity check overdue** (INFO): `last(/HOST/gmail_stack.borg_check_age)>14`
- **Orphan prune failing** (WARN): `last(/HOST/gmail_stack.prune_last_errors)>0`
  (IMAP re-check disagreed with mbsync, or the post-prune resync itself failed —
  investigate `/var/log/gmail_stack/prune_orphans.log`; a normal "found and
  removed an orphan" run reports 0 errors)
- **Orphan prune stale** (INFO): `last(/HOST/gmail_stack.prune_last_run)<`now`-3600`
  (should update every ~15 min via cron)

Note: `-1` means "unknown/not yet collected" — account for it in triggers if
needed (e.g. `>90` won't fire on `-1`, which is fine; add `and <>-1` where a
`-1` could otherwise trip a comparison).
