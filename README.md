# gmail_stack

Lokális, LAN-only Docker stack, ami a Gmail leveleket és a Google Calendart
egyirányban tükrözi, natív IMAP/CalDAV fiókként elérhetően (mobil/laptop),
plusz egy opcionális Roundcube webmail nézettel. A teljes adat a meglévő
Borg-backup rendszerbe van bekötve.

Fut: raspi (`ssh raspi`, LAN IP `192.168.1.25`), ugyanazon a gépen, ahol a
Syncthing Docker-stack is fut, ugyanazokat a konvenciókat követve.

## Architektúra

| Szolgáltatás | Szerep |
|---|---|
| `dovecot` | IMAP szerver (993, TLS), Maildir, `192.168.1.25`-re bindolva |
| `mbsync-sync` | Gmail → Maildir egyirányú szinkron 15 percenként |
| `radicale` | CalDAV szerver, Apache mögött `/radicale` alatt |
| `vdirsyncer-sync` | Google Calendar → Radicale egyirányú szinkron 15 percenként |
| `roundcube` | webmail UI, Apache mögött `/mail` alatt |

`ikermail.ddns.net` egyetlen domain, Apache vhost mögött, de **csak LAN-ról
(192.168.1.0/24)** érhető el — a raspi Apache-ja más domainekhez már
megosztva használja a 80/443-at, ezért az elérés-korlátozás a vhost szintjén
(`Require ip`) van, nem a tűzfalon. Lásd `apache/ikermail.ddns.net.conf.template`.

## Telepítés a raspi-n

### 1. Repo a helyére

```sh
ssh raspi
sudo mkdir -p /opt/stacks/gmail_stack
sudo chown ikerszig:ikerszig /opt/stacks/gmail_stack
git clone <ez a repo> /opt/stacks/gmail_stack
sudo mkdir -p /srv/gmail_stack/data/{maildir,radicale,roundcube-db}
sudo chown -R 1000:1000 /srv/gmail_stack/data
```

### 2. Let's Encrypt cert

Vedd fel az `ikermail.ddns.net` hostname-et a meglévő DDNS-fiókba (ez már
megtörtént), majd add hozzá a meglévő certbot-folyamathoz ugyanúgy, ahogy a
többi domaint (`ikersync.ddns.net` stb.) — standalone móddal, a meglévő
renewal-cronba illesztve. Ne hozz létre új, külön certbot-folyamatot.

### 3. Secrets kitöltése

Kövesd a `secrets/README.md`-t lépésről lépésre:
- Gmail App Password → `mbsync/conf/.mbsyncrc`
- Google OAuth kliens → `vdirsyncer/conf/config`
- Dovecot passwd-file → `dovecot/conf/passwd`
- Radicale htpasswd → `radicale/conf/users` (ld. `radicale/conf/users.README.md`)

### 4. Stack indítása

```sh
cd /opt/stacks/gmail_stack
docker compose build
docker compose up -d
docker compose logs -f dovecot mbsync-sync
```

### 5. Google Calendar egyszeri OAuth authorizáció

```sh
docker compose run --rm vdirsyncer-sync vdirsyncer discover google_calendar
```

Ez kiír egy böngészős authorizációs URL-t — nyisd meg egy géppel, ahol be
vagy jelentkezve a Google-fiókba, engedélyezd, majd a kapott kódot/tokent a
vdirsyncer visszaírja a `google_token.json`-be. Ezután a `vdirsyncer-sync`
konténer újraindítva már magától szinkronizál.

### 6. Apache vhost

```sh
sudo cp apache/ikermail.ddns.net.conf.template /etc/apache2/sites-available/ikermail.ddns.net.conf
# szerkeszd, ha kell (container IP-k változhatnak, ha a compose subnet más lenne)
sudo a2ensite ikermail.ddns.net
sudo apache2ctl configtest
sudo systemctl reload apache2
```

### 7. Tűzfal

Kövesd a `firewall/nftables-snippet.md`-t — add hozzá a `gmail_stack_net`
subnet accept szabályt, majd `sudo /root/Firewall/fw_load.sh` (SOHA `nft
flush ruleset`, az kiüti a Docker saját chain-jeit is).

### 8. Borg backup bekötése

```sh
sudo cp backup/gmail_stack_borg.sh /root/backup/modules/gmail_stack_borg.sh
sudo chmod +x /root/backup/modules/gmail_stack_borg.sh
```

A script a `syncthing_borg.sh` mintáját követi: ha a távoli repo még nem
létezik, `ensure_repo()` automatikusan létrehozza (`borg init`), nincs külön
manuális lépés. A fő `system_backup.sh` a `modules/*.sh` glob alapján
automatikusan felveszi, `sh gmail_stack_borg.sh <local_backup_dir>` formában
hívja meg (a helyi staging dir argumentumot a script nem használja, csak a
konzisztencia miatt kapja meg, mint a többi modul).

Egyszeri próbafuttatás a cronra várás nélkül:

```sh
sudo sh /root/backup/modules/gmail_stack_borg.sh /home/backup/SystemBackups
```

### 9. Kliens-oldali névfeloldás

Mivel nincs Pi-hole a hálózaton, minden eszközön (telefon, laptop), ahonnan
elérnéd a `ikermail.ddns.net`-et, vegyél fel egy hosts-bejegyzést:

```
192.168.1.25   ikermail.ddns.net
```

(Windows: `C:\Windows\System32\drivers\etc\hosts`, admin jogosultsággal.
Androidon root vagy egy helyi DNS-app kell hozzá — ha ez túl macerás, a
mail/naptár kliensben megadhatod közvetlenül a `192.168.1.25` IP-t is,
cserébe a TLS-kliens hostname-mismatch figyelmeztetést dobhat.)

## Ellenőrzés

- `openssl s_client -connect 192.168.1.25:993 -servername ikermail.ddns.net`
  — IMAP TLS kapcsolat teszt
- Roundcube: `https://ikermail.ddns.net/mail/` böngészőből, LAN-ról
- Radicale: naptár-app hozzáadása CalDAV fiókként,
  `https://ikermail.ddns.net/radicale/REPLACE_WITH_USERNAME/` URL-lel
- Külső hálózatról (mobilnet, WiFi kikapcsolva) próbáld elérni
  `https://ikermail.ddns.net/mail/`-t — 403-at kell kapnod (LAN-only ellenőrzés)
- `docker compose logs mbsync-sync` / `vdirsyncer-sync` — sikeres
  szinkron-ciklusok látszanak, nem crash-loop
