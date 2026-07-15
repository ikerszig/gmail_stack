# Radicale users file

The real `users` file (htpasswd format) is gitignored — generate it on the
raspi with:

```sh
docker run --rm -v "$(pwd)/radicale/conf:/config" httpd:alpine \
  htpasswd -B -c /config/users REPLACE_WITH_USERNAME
```

(`-B` = bcrypt, matching `htpasswd_encryption = bcrypt` in `config`.)
