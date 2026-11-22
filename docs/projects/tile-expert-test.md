# Project `tile-expert-test`: JSON REST API (Symfony + MySQL + Manticore)

Test task for Tile Expert, in `/home/dad/workspace/www/tile-expert-test`, public at `https://tile-expert-test.lucked.me` (the main domain of the project). Repository: `git@github.com:LuckedMe/tile-expert-test.git`.

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

## Step 23. Install and operate

Goal: the project runs in `/home/dad/workspace/www/tile-expert-test` behind the same Traefik and the same Cloudflare Tunnel as the other projects.

| URL | Purpose |
|---|---|
| `https://tile-expert-test.lucked.me/api/...` | the JSON API (`/api/products`, `/api/orders`, `/api/orders/{id}`) |
| `https://tile-expert-test.lucked.me/api/doc` | Swagger UI (NelmioApiDocBundle) |

```
Browser ──https──► Cloudflare ──tunnel──► cloudflared ──http──► traefik:80
                                 Host: tile-expert-test.lucked.me │ router from nginx labels
                                                                  ▼
                           nginx ─► php-fpm ─► mysql
                                          └──► manticore (orders search index)
```

How it is wired. The repo has **only a development compose file** (`docker-compose.yaml`): the code is bind-mounted into php-fpm, nginx/MySQL/Manticore/Adminer are published on `0.0.0.0`, the database password is `password`. We do **not** edit the repo. Instead a server-only `docker-compose.override.yaml` (template: [`docs/tile-expert-test/docker-compose.override.yaml`](tile-expert-test/docker-compose.override.yaml); the project git-ignores that file name, and docker compose merges it automatically) does three things:

- removes every published port (`ports: !reset []`): published Docker ports bypass `ufw`, and MySQL/Adminer must never be public;
- puts `nginx` into the shared `reverse-proxy` network with Traefik labels (the step 20 pattern: router `tile-expert-test`, entrypoint `web`, no redirect, no certresolver);
- keeps Adminer out of the default start (profile `debug`).

So every command is a plain `docker compose ...` run in the project folder. The environment-specific settings (`APP_SECRET`, `DEFAULT_URI`, CORS) go into the git-ignored `.env.local`. MySQL and Manticore are reachable only inside the project network, so the dev credentials in the compose file are not exposed. `APP_ENV` is already `prod` in the repo's `.env`.

### 23.0 Requirements

- Steps 1–10 are done (Docker, `reverse-proxy` network, Traefik, `cloudflared` running) and steps 18.1/18.2 (tunnel and HTTPS-only settings) are in place.
- Docker Compose 2.24.4 or newer (`docker compose version`), needed for `!reset`. The Docker from step 8 is new enough.
- The server user must have uid/gid 1000 (`id`, true for a fresh Ubuntu `dad`): php-fpm runs as uid 1000 and writes `var/` and `vendor/` in the bind-mounted folder. Otherwise run every `docker compose` command with `COMPOSE_USER_ID=$(id -u) COMPOSE_GROUP_ID=$(id -g)` in front.
- RAM and disk: the php-fpm image compiles PHP extensions, so swap (step 6) must exist. Free disk: `df -h /home`.
- Step 11 (deploy key) is done. GitHub accepts a public key as a Deploy key on **one** repository only, so this project gets its own key (23.2).

### 23.1 Cloudflare: public hostname (browser)

Zero Trust → Networks → Tunnels → `vps` → **Published application routes** → **Add** (see 18.1 for the fields):

| Subdomain | Domain | Path | Type | URL |
|---|---|---|---|---|
| `tile-expert-test` | `lucked.me` | empty | `HTTP` | `traefik:80` |

Cloudflare creates the proxied CNAME record `tile-expert-test` itself (delete an existing record with that name first). The name is one level below `lucked.me`, so the free Universal SSL certificate covers it. The HTTPS-only settings from 18.2 apply to the whole zone.

### 23.2 Clone the repository (server)

Create a separate key and an ssh host alias for this repository:

```bash
ssh-keygen -t ed25519 -C "dad@vps-main tile-expert-test" -f ~/.ssh/id_ed25519_tile_expert_test -N ""
cat ~/.ssh/id_ed25519_tile_expert_test.pub    # add it: GitHub LuckedMe/tile-expert-test → Settings → Deploy keys (read-only)

cat >> ~/.ssh/config <<'CFG'
Host github-tile-expert-test
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_tile_expert_test
    IdentitiesOnly yes
CFG
chmod 600 ~/.ssh/config

ssh -T git@github-tile-expert-test            # "Hi LuckedMe/tile-expert-test! You've successfully authenticated"
cd /home/dad/workspace/www
git clone git@github-tile-expert-test:LuckedMe/tile-expert-test.git tile-expert-test
cd /home/dad/workspace/www/tile-expert-test
```

(If the server's existing key is not a Deploy key anywhere else, you can skip the alias and clone with `git@github.com:LuckedMe/tile-expert-test.git`.)

> `COMPOSE_PROJECT_NAME=tile-expert-test` is set in the repo's `.env`, so containers, the network and the Manticore volume are named `tile-expert-test-*` / `tile-expert-test_*`. The folder name matches it. Do not rename either after the first start, or Docker creates new empty volumes.

### 23.3 Secrets and settings

```bash
cd /home/dad/workspace/www/tile-expert-test
# on your machine: copy the template; or create .env.local by hand from the table below
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/tile-expert-test/.env.local.dist dad@100.91.57.78:/home/dad/workspace/www/tile-expert-test/.env.local

# on the server
chmod 600 .env.local
openssl rand -hex 32                      # → APP_SECRET
nano .env.local
```

| Variable | Value |
|---|---|
| `APP_ENV` | `prod` |
| `APP_SECRET` | output of `openssl rand -hex 32` |
| `TIMEZONE` | `UTC` or `Europe/Kyiv` |
| `DEFAULT_URI` | `https://tile-expert-test.lucked.me/` |
| `CORS_ALLOW_ORIGIN` | `'^https://tile-expert-test\.lucked\.me$'` (add other origins with `\|` if other sites call the API from a browser) |

Not changed on purpose: `DATABASE_URL` (`mysql://user:password@mysql:3306/tile_expert_test_backend`, matches the compose file and stays inside the project network), `MANTICORE_URL`, `MESSENGER_TRANSPORT_DSN=sync://` (no worker needed), `PRODUCT_PAGE_URL_TEMPLATE`, `PRODUCT_PRICE_CACHE_TTL`. Symfony already trusts the private ranges as proxies (`trusted_proxies` in `config/packages/framework.yaml`), so with `trustedips` from step 18.3 the app sees `https` and the real client IP.

### 23.4 Production override and start

```bash
# on your machine
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/tile-expert-test/docker-compose.override.yaml dad@100.91.57.78:/home/dad/workspace/www/tile-expert-test/docker-compose.override.yaml

# on the server
cd /home/dad/workspace/www/tile-expert-test
git status --short                                # clean: the override and .env.local are git-ignored
docker compose config > /dev/null && echo OK
docker compose config | grep -c 'published'       # 0: no published ports
docker compose up -d --build                      # first build takes 5–15 minutes (PHP extensions)
docker compose ps                                 # php-fpm, nginx, mysql, manticore Up (no adminer)
```

If you changed the domain, edit the ``Host(`...`)`` rule in the override first. Router and service names (`tile-expert-test`) must be unique among projects (step 20).

### 23.5 Install the application

The code is bind-mounted, so dependencies are installed into the project folder through the container (neither PHP nor Composer is needed on the server):

```bash
cd /home/dad/workspace/www/tile-expert-test
docker compose exec php-fpm composer install --no-dev --optimize-autoloader --no-interaction
docker compose exec php-fpm bin/console cache:warmup
docker compose exec php-fpm bin/console doctrine:migrations:migrate --no-interaction    # MySQL must be up; wait ~30 s after the first start
docker compose exec php-fpm bin/console app:order:reindex                               # builds the Manticore `orders` index from MySQL
```

`make setup` from the README is **not** used on the server: it installs dev dependencies and creates the test database.

### 23.6 Verify

```bash
# on the server (through Traefik, with the right Host header)
curl -sI -H 'Host: tile-expert-test.lucked.me' http://127.0.0.1/api/doc | head -3                 # 200, not 404
curl -s  -H 'Host: tile-expert-test.lucked.me' 'http://127.0.0.1/api/orders?group_by=month'        # JSON {"items":[...],"meta":{...}}

# from outside the tailnet
curl -sI http://tile-expert-test.lucked.me/api/doc  | head -3     # 301 to https (Cloudflare)
curl -sI https://tile-expert-test.lucked.me/api/doc | head -3     # 200, valid certificate
curl -s  https://tile-expert-test.lucked.me/api/orders             # JSON
```

In the browser: `https://tile-expert-test.lucked.me/api/doc` opens Swagger UI. `docker ps` must show no published port for the project containers (only Traefik has `ports:`). Ready-to-run requests for every endpoint are in the repo: `tests/_https/orders/*.http` (change the `@host` variable).

`GET /api/products` depends on tile.expert, which protects its pages with a Cloudflare challenge: from a server IP it can answer `403`, reported by the API as `400` (a limitation of the project, not of the deployment).

### 23.7 Updating

```bash
cd /home/dad/workspace/www/tile-expert-test
git pull
docker compose up -d --build                                                            # only needed when .docker/* or the compose file changed
docker compose exec php-fpm composer install --no-dev --optimize-autoloader --no-interaction
docker compose exec php-fpm bin/console doctrine:migrations:migrate --no-interaction
docker compose exec php-fpm bin/console cache:clear
docker compose exec php-fpm bin/console app:order:reindex                               # only if the search fields/index changed
docker image prune -f
```

### 23.8 Backups

MySQL is the source of truth; the Manticore index is rebuilt with `app:order:reindex`, so it is not backed up. Create `/home/dad/workspace/backups/backup-tile-expert-test.sh` (nano, or a heredoc with a delimiter other than `EOF`):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/dad/workspace/www/tile-expert-test
STAMP=$(date +%F_%H%M)
docker compose exec -T mysql \
  sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
  | gzip > /home/dad/workspace/backups/dump/tile-expert-test-$STAMP.sql.gz
find /home/dad/workspace/backups/dump -name 'tile-expert-test-*.sql.gz' -mtime +7 -delete
```

```bash
chmod 700 /home/dad/workspace/backups/backup-tile-expert-test.sh
/home/dad/workspace/backups/backup-tile-expert-test.sh && ls -lh /home/dad/workspace/backups/dump | tail -3
( crontab -l 2>/dev/null; echo '20 3 * * * /home/dad/workspace/backups/backup-tile-expert-test.sh >> /home/dad/workspace/backups/backup.log 2>&1' ) | crontab -
```

Restore: `gunzip -c /home/dad/workspace/backups/dump/tile-expert-test-<stamp>.sql.gz | docker compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'`, then `app:order:reindex`.

### 23.9 Rollback / removal and troubleshooting

- Take the site offline only: delete the `tile-expert-test` route in the tunnel (Zero Trust → Tunnels → `vps`), or `docker compose stop nginx`.
- Stop everything, keep data: `docker compose down`.
- Full removal (**destroys the database and the search index**; back up first): `docker compose down -v`, then `rm -rf /home/dad/workspace/www/tile-expert-test` (the database lives in `.docker/mysql/data` inside the folder).
- Database console (Adminer stays off, it has no public route): `docker compose exec mysql mysql -uroot -ppassword tile_expert_test_backend`.

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik | nginx is not in the `reverse-proxy` network or has no labels (override missing: `docker compose config \| grep traefik`), or the Host is not `tile-expert-test.lucked.me`. |
| `502`/`504` from Traefik | nginx or php-fpm is not up (`docker compose ps`, `docker compose logs nginx php-fpm`). |
| `502` from Cloudflare | The tunnel route URL is not `http://traefik:80`, or the `tile-expert-test` hostname is missing in the tunnel. |
| Nginx `502 Bad Gateway` right after the start | php-fpm is still starting, or `vendor/` is missing: run 23.5. |
| `Class "..." not found` / 500 on every URL | `composer install` was not run (23.5), or `var/` is not writable: `ls -ln var` must show uid 1000; fix with `sudo chown -R 1000:1000 var vendor`. |
| `Bind for 0.0.0.0:8080 failed` / port already allocated | The override is missing, so the dev ports are published again: copy it (23.4) and `docker compose up -d`. |
| Orders search returns nothing | The index is empty: `docker compose exec php-fpm bin/console app:order:reindex` (without Manticore the API falls back to MySQL `LIKE`). |
| `SQLSTATE[HY000] [2002]` during migrations | MySQL has not finished its first start: `docker compose logs mysql`, wait and repeat. |
| Links with `http://`, wrong client IP | `forwardedheaders.trustedips` is missing in Traefik (18.3). |
| Build killed (137) | Add swap (step 6). |
| `services.nginx.ports must be a mapping` / unknown tag `!reset` | Docker Compose older than 2.24.4: update Docker (step 8). |
