# Secrets checklist

None of the files below are committed to git (see `.gitignore`). Fill them in
on the raspi after cloning the repo into `/opt/stacks/gmail_stack`.

| File (real, gitignored) | From template | What goes in it |
|---|---|---|
| `mbsync/conf/.mbsyncrc` | `mbsync/conf/.mbsyncrc.template` | Gmail address + [App Password](https://myaccount.google.com/apppasswords) (needs 2FA enabled on the Google account) |
| `vdirsyncer/conf/config` | `vdirsyncer/conf/config.template` | Google OAuth client id/secret (Google Cloud Console → APIs & Services → Credentials → OAuth client ID → Desktop app; enable the Google Calendar API for the project) + the Radicale username/password chosen below |
| `vdirsyncer/conf/google_token.json` | — (generated) | Created automatically the first time you run `docker compose run --rm vdirsyncer-sync vdirsyncer discover google_calendar` interactively (opens a one-time browser authorization URL — do this over SSH with a browser on your own machine, following the URL vdirsyncer prints) |
| `dovecot/conf/passwd` | — (generated) | Dovecot passwd-file format: `email@gmail.com:{SHA512-CRYPT}$6$...`. Generate the hash with `doveadm pw -s SHA512-CRYPT` (run inside the dovecot container: `docker compose exec dovecot doveadm pw -s SHA512-CRYPT`) |
| `radicale/conf/users` | `radicale/conf/users.README.md` | htpasswd (bcrypt) — see that file for the exact command |

## Notes

- The Gmail App Password and the Radicale/Dovecot local passwords are
  **different things** — the App Password only lets `mbsync` read Gmail;
  the Dovecot/Radicale passwords are what you type into your phone/laptop's
  mail and calendar apps to reach the local mirror.
- The Google OAuth refresh token (`google_token.json`) can expire after ~6
  months of inactivity while the Cloud project is in "Testing" publishing
  status. Moving the OAuth consent screen to "In production" (no
  Google verification needed for personal use, just a checkbox) avoids that.
