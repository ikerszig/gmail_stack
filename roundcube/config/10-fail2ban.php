<?php
// A kepnernek induláskor (docker-entrypoint.sh) automatikusan be kell húznia
// ezt a fájlt: minden /var/roundcube/config/*.php fájlt include-ol.
//
// Alapertelmezetten log_driver=stdout és log_logins=false - a sikertelen
// bejelentkezesek sehol nem hagynak nyomot. 2026-08-08: fail2ban-hoz kell
// egy tenyleges naplofajl.
$config['log_driver'] = 'file';
$config['log_logins'] = true;
