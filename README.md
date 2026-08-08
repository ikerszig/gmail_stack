# gmail_stack

Lokális, LAN-only Docker stack, ami a Gmail leveleket és a Google Calendart
egyirányban tükrözi, natív IMAP/CalDAV fiókként elérhetően (mobil/laptop),
plusz egy opcionális Roundcube webmail nézettel. A teljes adat a meglévő
Borg-backup rendszerbe van bekötve.

Fut: raspi (`ssh raspi`, LAN IP `192.168.1.25`), ugyanazon a gépen, ahol a
Syncthing Docker-stack is fut, ugyanazokat a konvenciókat követve.

## Állapot (2026-07-16)

Telepítve és fut a raspi-n. Kész: repo `/opt/stacks/gmail_stack`, adat
`/srv/gmail_stack/data`, LE cert, Dovecot+Radicale lokális fiókok, mind az öt
konténer fut, Gmail-szinkron folyamatban (első teljes lehúzás), Apache vhost
(LAN-only), Borg backup bekötve+tesztelve, `ikerszig_save@ikermail.ddns.net`
tároló-fiók létrehozva. **Hátra:** Google Calendar OAuth (5. lépés), kliens
hosts-bejegyzés + végpont-ellenőrzés (9. lépés).

## Architektúra

| Szolgáltatás | Szerep |
|---|---|
| `dovecot` | IMAP szerver (993, TLS), Maildir, `192.168.1.25`-re bindolva |
| `mbsync-sync` | Gmail → Maildir egyirányú szinkron 15 percenként |
| `radicale` | CalDAV szerver, Apache mögött `/radicale` alatt |
| `vdirsyncer-sync` | Google Calendar → Radicale egyirányú szinkron 15 percenként |
| `roundcube` | webmail UI, Apache mögött `/mail` alatt |

Monitoring: Zabbix UserParameters a sync-élettartamhoz és a Borg-egészséghez,
lásd `monitoring/` (root cron gyűjt → agent olvas).

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

### 9. Kliens-oldali elérés (2026-08-05 óta: helyi DNS + WireGuard)

> **Ez a szakasz 2026-08-05-én teljesen átíródott.** A korábbi leírás azt
> állította, hogy a router NAT-hairpinje LAN forrás-IP-t mutat a raspinak, és
> hogy ezen múlik a mobil-elérés. **Ez méréssel cáfolt** — lásd lent.

#### A tényleges viselkedés (mérve, nem feltételezve)

A router hairpinel ugyan, de közben **SNAT-ol a saját WAN-címére**. Ugyanabból
a másodpercből az Apache-naplóban:

```
ikermail.ddns.net:443 37.76.120.99  ... "GET /mail/" 403   ← hairpin út
ikermail.ddns.net:443 192.168.1.45  ... "GET /mail/" 200   ← közvetlen LAN
```

Vagyis a raspi a hairpinelt LAN-forgalmat **nem tudja megkülönböztetni** egy
valódi internetes kéréstől. A régi „993-forward + source-IP szűrés" terv ezért
nem is működhetett volna — és a 48 órás tűzfal-naplóban valóban **nulla**
találat volt a 993-as portra a WAN felől.

#### Amin ezen felül elbukott (és amit senki nem vett észre)

A `docker-compose.yml` deklarálta a `ports: - "192.168.1.25:993:993"` sort, de
a **futó konténer port-publish nélkül jött létre** (elavult
`com.docker.compose.config-hash`): a hoston **semmi nem figyelt a 993-on**.
A Dovecot a konténeren belül rendben figyelt, kívülről viszont nem volt mihez
csatlakozni. Egy `docker compose up -d dovecot` oldotta meg.

**Tanulság**: ha a compose-ban benne van egy port, az még nem jelenti, hogy a
futó konténeren is rajta van. Ellenőrzés:
`docker inspect <c> --format '{{json .NetworkSettings.Ports}}'`.

#### A mostani megoldás

**Helyi split-horizon DNS** (AdGuard Home a raspin, `192.168.1.25` és
`10.9.0.1` címeken) az `ikermail.ddns.net`-et a **LAN-IP-re** oldja fel. A név
változatlan marad, ezért a Let's Encrypt tanúsítvány továbbra is illeszkedik —
IMAPS-nél ez kritikus, nyers IP-vel a levelezőkliens cert-hibát dobna.

| Eszköz | Hogyan kapja a helyes feloldást |
|---|---|
| Android | WireGuard tunnel `DNS = 10.9.0.1` — otthon és mobilneten egyaránt |
| Windows | ugyanígy a tunnelen; tunnel nélkül a Wi-Fi adapter DNS-e (`192.168.1.25`) |

⚠️ **Publikus DNS-t SOHA ne adj meg másodlagosnak** a kliensen. Split-horizonnál
az ugyanarra a névre *más* választ ad; a Windows pedig rendszeresen a
másodlagost kérdezi (nem csak az elsődleges kiesésekor). 2026-08-05-én egy
`1.1.1.1` másodlagos pontosan ezért okozott szórványos 403-akat.

**Külső elérés**: a levelezés LAN + VPN-ről érhető el (`Require ip` a vhoston,
`10.9.0.0/24` is engedve). Mobilneten a WireGuard tunnelen keresztül működik —
nincs szükség 993-as port-forwardra, tehát az IMAP **soha nem néz a netre**.

**Avast/AV buktató (Windows):** ha a kliensgépen fut Avast (vagy hasonló AV)
Mail/Web Shield SSL-szkenneléssel, az MITM-eli az IMAPS-kapcsolatot és a saját
gyökér-certjét tolja be — a Thunderbird ezt (főleg ha az AV nem éri el az
upstream szervert, pl. forward nélkül) elutasíthatja "jelszó-kérés nélkül".
Megoldás: Avast → Core Shields → Web/Mail Shield → HTTPS/SSL scanning kikapcs,
VAGY hagyd bekapcsolva (az Avast a saját gyökeret a Thunderbird NSS-tárába is
beinjektálja, így általában megbízik benne). A forward megléte önmagában is
sokat javít, mert az AV így validálni tudja a valódi certet.

## Extra tároló-fiók (nem Gmail-mirror)

A `dovecot/conf/passwd`-ben a Gmail-mirror fiók mellett létezik egy külön
tároló-postafiók: `ikerszig_save@ikermail.ddns.net`. Ez NEM szinkronizál
sehonnan — üres IMAP-fiók, ahová kézzel (a mail-kliensből áthúzva / IMAP
APPEND-del) pakolhatók a megőrzendő levelek/adatok. Nincs SMTP, tehát csak
tárolásra/fogadásra való, küldésre nem. A postafiókja
`/srv/gmail_stack/data/maildir/ikerszig_save@ikermail.ddns.net` alatt van,
így a Borg-mentés (ami a teljes `/srv/gmail_stack/data`-t viszi)
automatikusan lementi — nincs külön teendő.

Új fiók felvétele később: hash generálása
`docker compose exec dovecot doveadm pw -s SHA512-CRYPT`, a
`user:hash` sor hozzáfűzése a `dovecot/conf/passwd`-hez, majd a
`/srv/gmail_stack/data/maildir/<user>/{cur,new,tmp}` létrehozása
`chown 1000:1000`-rel. Dovecot-restart nem kell (passwd-file minden auth-nál
újraolvasva).

### 10. Roundcube: sikertelen bejelentkezes naplozasa fail2ban-hoz (2026-08-08)

Alapertelmezetten a Roundcube **semmit nem naplozott**: `log_logins = false`
es `log_driver = 'stdout'` (a hivatalos Docker kep alapertelmezese), tehat
sikertelen bejelentkezesrol sehol nem maradt nyom.

**Megoldas**: `roundcube/config/10-fail2ban.php` — a hivatalos kepkezelo
(`docker-entrypoint.sh`) minden `/var/roundcube/config/*.php` fajlt
automatikusan `include()`-ol induláskor, ez a dokumentalt bovitesi pont, nem
kell a teljes `config.inc.php`-t felulirni. A fajl `log_driver`-t `file`-ra
allitja es `log_logins`-t bekapcsolja; a `docker-compose.yml` bind-mountolja
`/srv/gmail_stack/data/roundcube-config` (a config fajl) es `/var/log/roundcube`
(a naplo maga) konyvtarakat.

**⚠️ Biztonsagi reszlet, elo teszttel felfedve**: a Roundcube naplosora
mindig `REMOTE_ADDR (X-Forwarded-For: ...)` formatumu (fix, nem
konfiguralhato — l. `rcube_utils::remote_ip()`). A `REMOTE_ADDR` itt **mindig**
a Docker-halozat gateway-cime (`172.28.0.1`, az Apache proxy felol erkezo
kapcsolat latszolagos forrasa) — a valodi kliens cime a zarojelben van.

Az `X-Forwarded-For` fejlec viszont **hamisithato**: egy kliens sajat maga is
kuldhet ilyen fejlecet. Elo teszttel igazolva: egy sajat kezzel kuldott
`X-Forwarded-For: 6.6.6.6` fejlecre a naplo
`(X-Forwarded-For: 6.6.6.6, 192.168.1.25)`-ot irt — **Apache nem cserelte le**
a hamisitott erteket, hanem **hozzafuzte** a valodi cimet a lista **vegehez**
(mod_proxy alapviselkedes). A fail2ban-szuro (`RaspiBackup/fail2ban/filter.d/
roundcube.conf`) ezert mindig az **utolso** IP-t veszi a listabol — ha az
elsot venne, barki barmilyen artatlan IP-t kitilthatna (fail2ban-alapu
DoS sajat magunk ellen). Elo teszttel megerositve: a spoofolt `6.6.6.6` sehol
nem kerult be egyetlen `f2b_*` setbe sem, csak a valodi `192.168.1.25`.

Ez ugyanaz a mintazat, mint a korabbi Zabbix (`WEB_REAL_IP_FROM`) es
Vaultwarden (`TRUSTED_PROXIES`) root-cause javitasok: reverse proxy mogott a
kliens-IP sosem magatol ertetodo, mindig elo teszttel, hamisitott fejleccel
is le kell ellenorizni.

**A jail (`RaspiBackup/fail2ban/jail.d/roundcube.conf`) elovigyazatossagi
jellegu**: a webmail ma csak LAN+VPN-rol erheto el (2026-08-06-i
szigoritas), tehat kivulrol ma nem tamadhato — de "ha egyszer ki lesz nyitva,
mukodjon" (felhasznaloi keres). Elo ban-teszttel igazolva: 5 sikertelen
probalkozas → tiltas → az IP bekerult az `f2b_roundcube` setbe → feloldva.

## Ellenőrzés

- `openssl s_client -connect 192.168.1.25:993 -servername ikermail.ddns.net`
  — IMAP TLS kapcsolat teszt
- Roundcube: `https://ikermail.ddns.net/mail/` böngészőből, LAN-ról
- Radicale: naptár-app hozzáadása CalDAV fiókként,
  `https://ikermail.ddns.net/radicale/REPLACE_WITH_USERNAME/` URL-lel
- Külső hálózatról (mobilnet, WiFi kikapcsolva, **WireGuard nélkül**) próbáld
  elérni `https://ikermail.ddns.net/mail/`-t — 403-at kell kapnod
- Ugyanaz **WireGuard tunnellel**: 200-at kell kapnod (a `Require ip` a
  `10.9.0.0/24`-et is engedi)
- Dovecot-napló (2026-08-05 óta van egyáltalán):
  `docker logs gmail_stack_dovecot` — a sikeres bejelentkezés `rip=` mezője
  mutatja a valódi forrás-IP-t (VPN-ről `10.9.0.4`, LAN-ról `192.168.1.x`)
- `docker compose logs mbsync-sync` / `vdirsyncer-sync` — sikeres
  szinkron-ciklusok látszanak, nem crash-loop
