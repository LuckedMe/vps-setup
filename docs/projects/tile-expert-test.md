# Project `tile-expert-test`: JSON REST API (Symfony + MySQL + Manticore)

Test task for Tile Expert, in `/home/dad/workspace/www/tile-expert-test`, public at `https://tile-expert-test.lucked.me` (the main domain of the project). Repository: `git@github.com:LuckedMe/tile-expert-test.git`.

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

The project-side, self-contained version of this guide is `docs/deploy.md` in the project repository; the reasons behind its `Dockerfile` and compose file are in `docs/main-dockerfile-fix.md` there. If the two differ, the project repository wins.

## Step 23. Install and operate

Goal: the project runs in `/home/dad/workspace/www/tile-expert-test` behind the same Traefik and the same Cloudflare Tunnel as the other projects.

| URL | Purpose |
|---|---|
| `https://tile-expert-test.lucked.me/api/...` | the JSON API (`/api/products`, `/api/orders`, `/api/orders/{id}`) |
| `https://tile-expert-test.lucked.me/api/doc` | Swagger UI (NelmioApiDocBundle) |

```
Browser ──https──► Cloudflare ──tunnel──► cloudflared ──http──► traefik:80
                                 Host: tile-expert-test.lucked.me │ router from the nginx labels
                                                                  ▼
                           nginx ─► php-fpm ─► mysql
                                          └──► manticore (orders search index)
```

How it is wired. The repository has a **production stack of its own**, separate from the development one (`docker-compose.yaml`, bind-mounted code, dev passwords):

- the root `Dockerfile` builds the images on the server (targets `app` = php-fpm with the code baked in and no dev packages, `nginx`);
- `docker-compose.prod.yaml` (project name `tile-expert-test-prod`) starts `php-fpm`, `nginx`, `mysql` and `manticore`. It publishes **no port** (published Docker ports bypass `ufw`), and `nginx` joins the external `reverse-proxy` network with the Traefik labels of the step 20 pattern: router `tile-expert-test`, entrypoint `web`, no redirect, no certresolver. There is nothing to add to the Traefik folder and no `ufw` rule;
- the server-only settings live in the git-ignored `.env.prod.local` (template `.env.prod.local.dist` in the repository);
- `bin/deploy.sh` does a release: pull, database backup, build, restart, checks. With `--remote` it runs on this server over ssh from the developer's machine.

Data is in two named volumes: `mysql` (the source of truth) and `manticore` (the search index, rebuilt from MySQL with `app:order:reindex`). MySQL and Manticore are reachable only inside the project network.

### 23.0 Requirements

- Steps 1–10 are done (Docker, the `reverse-proxy` network, Traefik, `cloudflared` running) and steps 18.1/18.2 (tunnel and HTTPS-only settings) are in place.
- RAM and disk: the php-fpm image compiles PHP extensions, so swap (step 6) must exist. Free disk: `df -h /home` (the first build needs 2–3 GB).
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

> The compose file sets `name: tile-expert-test-prod`, so containers and volumes are named `tile-expert-test-prod-*` / `tile-expert-test-prod_*` whatever the folder is called. Do not change that name after the first start, or Docker creates new empty volumes (the database would "disappear").

### 23.3 Secrets and settings

```bash
cd /home/dad/workspace/www/tile-expert-test
cp .env.prod.local.dist .env.prod.local
chmod 600 .env.prod.local

openssl rand -hex 32        # → APP_SECRET
openssl rand -hex 24        # → MYSQL_PASSWORD
openssl rand -hex 24        # → MYSQL_ROOT_PASSWORD

nano .env.prod.local
```

| Variable | Value |
|---|---|
| `APP_IMAGE` / `APP_TAG` / `MANTICORE_VERSION` | leave `tile-expert-test` / `latest` / `32.1.3` |
| `RUN_MIGRATIONS` | `1`: migrations run when `php-fpm` starts |
| `MYSQL_DATABASE` / `MYSQL_USER` | `tile_expert_test` / `tile_expert_test` |
| `MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` | generated (hex only: nothing breaks the `DATABASE_URL`); used when MySQL creates its data directory on the first start |
| `APP_SECRET` | output of `openssl rand -hex 32` |
| `TIMEZONE` | `UTC` or `Europe/Kyiv` |
| `APP_DOMAIN` | `tile-expert-test.lucked.me` (the Traefik router rule uses it) |
| `DEFAULT_URI` | `https://tile-expert-test.lucked.me/` |
| `CORS_ALLOW_ORIGIN` | `^https://tile-expert-test\.lucked\.me$` (add other origins with `\|` if other sites call the API from a browser) |

Not set on purpose: `APP_ENV`/`APP_DEBUG` (the image sets `prod`/`0`), `DATABASE_URL` (the compose file builds it from `MYSQL_*`), `MANTICORE_URL`, `MESSENGER_TRANSPORT_DSN=sync://` (no worker). Symfony already trusts the private ranges as proxies (`trusted_proxies` in `config/packages/framework.yaml`), so with `trustedips` from step 18.3 the app sees `https` and the real client IP.

### 23.4 First start

```bash
cd /home/dad/workspace/www/tile-expert-test

git status --short                        # clean: .env.prod.local is git-ignored
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config -q && echo OK
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config | grep -c published            # 0: no published ports
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d --build                         # first build takes 5–15 minutes (PHP extensions, composer)
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local ps                                    # php-fpm, nginx, mysql (healthy), manticore Up
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local logs -f php-fpm                       # "Successfully migrated", "ready to handle connections"; Ctrl+C
```

Migrations ran when `php-fpm` started. The search index is created when the first order is saved; if the database already has orders, build it once: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm bin/console app:order:reindex` (or `bin/deploy.sh --reindex`).

If you changed the domain, set `APP_DOMAIN` in `.env.prod.local`. Router and service names (`tile-expert-test`) must be unique among projects (step 20).

### 23.5 Verify

```bash
# on the server (through Traefik, with the right Host header)
curl -sI -H 'Host: tile-expert-test.lucked.me' http://127.0.0.1/api/doc | head -1                  # 200, not 404
curl -s  -H 'Host: tile-expert-test.lucked.me' 'http://127.0.0.1/api/orders?group_by=month'        # JSON {"items":[...],"meta":{...}}

# from outside the tailnet
curl -sI http://tile-expert-test.lucked.me/api/doc  | head -3     # 301 to https (Cloudflare)
curl -sI https://tile-expert-test.lucked.me/api/doc | head -1     # 200, valid certificate
curl -s  https://tile-expert-test.lucked.me/api/orders             # JSON
```

In the browser: `https://tile-expert-test.lucked.me/api/doc` opens Swagger UI. `docker ps` must show no published port for the project containers (only Traefik has `ports:`). Ready-to-run requests for every endpoint are in the repository: `tests/_https/orders/*.http` (change the `@host` variable).

`GET /api/products` depends on tile.expert, which protects its pages with a Cloudflare challenge: from a server IP it can answer `403`, reported by the API as `400` (a limitation of the project, not of the deployment).

### 23.6 Updating

```bash
cd /home/dad/workspace/www/tile-expert-test
bin/deploy.sh                    # git pull --ff-only + backup + build + up -d + checks + image prune
bin/deploy.sh --reindex          # ...and rebuild the search index (after a release that changes the indexed fields)
bin/deploy.sh --ref <commit>     # roll back to a revision
```

From the developer's machine (push first; the script warns about unpushed commits): `bin/deploy.sh --remote [--reindex] [--ref <rev>]`. It opens an ssh session to `DEPLOY_HOST` (default `dad@100.91.57.78`) and runs the server's copy of the script in `DEPLOY_DIR` (default `/home/dad/workspace/www/tile-expert-test`). Other options: `--no-backup`, `--no-pull`, `--no-prune`, `--host`, `--dir`; environment `BACKUP_SCRIPT`, `APP_URL`. The script refuses to run with a `!ChangeMe!` placeholder in `.env.prod.local` or with local changes in the checkout. Details: `docs/deploy.md`, section 8 in the project.

### 23.7 Backups

MySQL is the source of truth; the Manticore index is rebuilt with `app:order:reindex`, so it is not backed up. Create `/home/dad/workspace/backups/backup-tile-expert-test.sh` (nano, or a heredoc with a delimiter other than `EOF`); `bin/deploy.sh` runs it before every update:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/dad/workspace/www/tile-expert-test
STAMP=$(date +%F_%H%M)
mkdir -p /home/dad/workspace/backups/dump
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec -T mysql \
  sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
  | gzip > /home/dad/workspace/backups/dump/tile-expert-test-$STAMP.sql.gz
find /home/dad/workspace/backups/dump -name 'tile-expert-test-*.sql.gz' -mtime +7 -delete
```

```bash
chmod 700 /home/dad/workspace/backups/backup-tile-expert-test.sh
/home/dad/workspace/backups/backup-tile-expert-test.sh && ls -lh /home/dad/workspace/backups/dump | tail -3
( crontab -l 2>/dev/null; echo '20 3 * * * /home/dad/workspace/backups/backup-tile-expert-test.sh >> /home/dad/workspace/backups/backup.log 2>&1' ) | crontab -
```

Restore: `gunzip -c /home/dad/workspace/backups/dump/tile-expert-test-<stamp>.sql.gz | docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'`, then `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm bin/console app:order:reindex`.

### 23.8 Rollback / removal and troubleshooting

- Take the site offline only: delete the `tile-expert-test` route in the tunnel (Zero Trust → Tunnels → `vps`), or `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local stop nginx`.
- Stop everything, keep data: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local down`.
- Full removal (**destroys the database and the search index**; back up first): `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local down -v`, then `rm -rf /home/dad/workspace/www/tile-expert-test`.
- Database console (there is no Adminer in production): `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'`.

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik | nginx is not in the `reverse-proxy` network or has no labels (`docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config \| grep traefik`), or the Host is not `APP_DOMAIN`. |
| `502`/`504` from Traefik | nginx or php-fpm is not up (`docker compose -f docker-compose.prod.yaml --env-file .env.prod.local ps`, `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local logs nginx php-fpm`). |
| `502` from Cloudflare | The tunnel route URL is not `http://traefik:80`, or the `tile-expert-test` hostname is missing in the tunnel. |
| `network reverse-proxy declared as external, but could not be found` | The shared infrastructure is not running (step 10): start Traefik or `docker network create reverse-proxy`. |
| php-fpm restarts in a loop | `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local logs php-fpm`: empty `APP_SECRET`, MySQL not healthy yet, or a failed migration. |
| `SQLSTATE[HY000] [1045] Access denied` | `MYSQL_PASSWORD` differs from the one MySQL was initialised with on the first start: restore the old value, or remove the `mysql` volume if the database is empty. |
| Orders search returns nothing | The index is empty: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm bin/console app:order:reindex` (without Manticore the API falls back to MySQL `LIKE`). |
| Build killed (137) | Add swap (step 6). |
| `bin/deploy.sh --remote`: `Permission denied (publickey)` | Your key is not authorised on the server, or Tailscale is down (`tailscale status`). |
| Links with `http://`, wrong client IP | `forwardedheaders.trustedips` is missing in Traefik (18.3). |
