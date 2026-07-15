# nftables changes for gmail_stack (raspi)

Add to `/root/Firewall/nftables.nft` inside `table inet firewall`, following
the existing pattern used for the Syncthing docker subnet, then reload with
`sudo /root/Firewall/fw_load.sh` (NEVER `nft flush ruleset` — see the
Syncthing stack notes on why that breaks Docker's own chains).

```
# gmail_stack docker subnet — allow container-to-container / outbound
ip saddr 172.28.0.0/24 accept
```

Dovecot's IMAPS port (993) is bound to the LAN interface IP in
docker-compose.yml (`192.168.1.25:993:993`). **This alone does NOT make it
LAN-only**, though: if the router port-forwards (or DMZs) WAN:993 to
192.168.1.25, the packet reaches Dovecot, and this firewall's broad
`ip saddr @hu_ipv4 accept` (all ports) would let any Hungarian IP in.
Observed in testing: 993 was reachable via the public IP from a LAN host,
so a forward/hairpin path exists. To guarantee LAN-only regardless of the
router, an explicit DROP is added — placed AFTER the general LAN accept
(`ip saddr 192.168.1.0/24 accept`, so LAN traffic has already matched) and
BEFORE the geoip allow, so only non-LAN traffic hits it:

```
tcp dport 993 drop
```

**Do NOT add a router port-forward for 993** — this stack is LAN-only by
design, unlike Syncthing's 22000 (which intentionally needed mobile-data
reachability). Even if one exists, the DROP above keeps external clients out.

Apache's 80/443 need no firewall changes — the existing rules for other
vhosts on this host already cover them, and the LAN-only requirement for
ikermail.ddns.net is enforced at the Apache vhost level (`Require ip
192.168.1.0/24`), not at the firewall.
