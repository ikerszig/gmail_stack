# gmail_stack monitoring (Zabbix)

"Root cron collects → Zabbix agent reads" pattern. A privileged cron writes a
fast, world-readable status file; the `zabbix` user only cats/awks it, so no
docker/root/borg access is needed at poll time.

## Deploy (raspi)

```sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_monitor.sh     /root/gmail_stack_monitor.sh
sudo cp /opt/stacks/gmail_stack/monitoring/gmail_stack_borg_check.sh  /root/gmail_stack_borg_check.sh
sudo chmod +x /root/gmail_stack_monitor.sh /root/gmail_stack_borg_check.sh
sudo cp /opt/stacks/gmail_stack/monitoring/zabbix_gmail_stack.conf /etc/zabbix/zabbix_agent2.d/gmail_stack.conf

# first run + agent reload
sudo /root/gmail_stack_monitor.sh
sudo systemctl restart zabbix-agent2
```

Root crontab:

```
*/15 * * * * /root/gmail_stack_monitor.sh >/dev/null 2>&1
30 8 * * 0   /root/gmail_stack_borg_check.sh >/dev/null 2>&1
```

Test locally (agent-side):

```sh
for k in sync_running dovecot_running sync_age_min sync_fail borg_age_hours borg_check borg_check_age; do
  printf '%s = ' "$k"; sudo -u zabbix zabbix_agent2 -t "gmail_stack.$k" 2>/dev/null | sed -E 's/.*\|(.*)\]/\1/'
done
```

## Zabbix items (create on the host in the Zabbix UI)

Type **Zabbix agent** (passive), numeric (unsigned/float), update interval 5m:

| Key | Meaning |
|---|---|
| `gmail_stack.sync_running` | mbsync container up (1/0) |
| `gmail_stack.dovecot_running` | Dovecot container up (1/0) |
| `gmail_stack.sync_age_min` | minutes since last sync loop start |
| `gmail_stack.sync_fail` | count of recent "sync failed" log lines |
| `gmail_stack.borg_age_hours` | age of newest Borg archive (hours) |
| `gmail_stack.borg_check` | last integrity check: 0 ok / 1 fail / -1 never |
| `gmail_stack.borg_check_age` | days since last integrity check |

## Suggested triggers

- **Dovecot down** (HIGH): `last(/HOST/gmail_stack.dovecot_running)=0`
- **mbsync down** (WARN): `last(/HOST/gmail_stack.sync_running)=0`
- **Sync stale** (WARN): `last(/HOST/gmail_stack.sync_age_min)>90`
  (loop runs ~every 30 min; >90 min = stuck/dead)
- **Sync failing** (AVG): `last(/HOST/gmail_stack.sync_fail)>2`
  (repeated failures — likely revoked App Password)
- **Backup stale** (HIGH): `last(/HOST/gmail_stack.borg_age_hours)>26`
  (nightly backup at 22:00 → should always be <26h)
- **Borg integrity fail** (HIGH): `last(/HOST/gmail_stack.borg_check)=1`
- **Integrity check overdue** (INFO): `last(/HOST/gmail_stack.borg_check_age)>14`

Note: `-1` means "unknown/not yet collected" — account for it in triggers if
needed (e.g. `>90` won't fire on `-1`, which is fine; add `and <>-1` where a
`-1` could otherwise trip a comparison).
