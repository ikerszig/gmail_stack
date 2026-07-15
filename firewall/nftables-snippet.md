# nftables changes for gmail_stack (raspi)

Add to `/root/Firewall/nftables.nft` inside `table inet firewall`, following
the existing pattern used for the Syncthing docker subnet, then reload with
`sudo /root/Firewall/fw_load.sh` (NEVER `nft flush ruleset` — see the
Syncthing stack notes on why that breaks Docker's own chains).

```
# gmail_stack docker subnet — allow container-to-container / outbound
ip saddr 172.28.0.0/24 accept
```

Dovecot's IMAPS port (993) is already bound to the LAN interface IP only in
docker-compose.yml (`192.168.1.25:993:993`), which is the primary control —
Docker's own iptables-nft chains have previously conflicted with this
firewall's custom rules (see Syncthing stack notes), so an interface-bound
publish is more robust here than relying purely on an nftables INPUT rule.
As a belt-and-suspenders measure you can still add:

```
ip saddr 192.168.1.0/24 tcp dport 993 accept
```

**Do NOT add a router port-forward for 993** — this stack is LAN-only by
design, unlike Syncthing's 22000 (which intentionally needed mobile-data
reachability).

Apache's 80/443 need no firewall changes — the existing rules for other
vhosts on this host already cover them, and the LAN-only requirement for
ikermail.ddns.net is enforced at the Apache vhost level (`Require ip
192.168.1.0/24`), not at the firewall.
