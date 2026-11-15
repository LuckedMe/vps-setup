# Project `cms`: CMS (Symfony + MySQL)

`cms-admin` in `/home/dad/workspace/www/cms`, one domain split by path: `https://cms.lucked.me` (main), `/admin` (admin section), `/api` (API).

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

## Step 22. Install and operate

Goal: the `cms` project runs in `/home/dad/workspace/www/cms` behind the same Traefik and the same Cloudflare Tunnel as the other projects. It uses **one domain**, `cms.lucked.me`, split by path:

| URL | Purpose | Served by |
|---|---|---|
| `https://cms.lucked.me` | the **main** domain of the project (public client site, 22.11) | the client app (22.11) |
| `https://cms.lucked.me/admin` | the **admin** section | `cms-admin` (`git@github.com:vtsot/cms-admin.git`) |
| `https://cms.lucked.me/api` | the **API** for communication between the clients and the admin functionality | the same `cms-admin` stack |

Steps 22.1–22.10 deploy the `cms-admin` stack (admin + API); 22.11 adds the client site on the root of the same domain.

```
Browser ──https──► Cloudflare ──tunnel──► cloudflared ──http──► traefik:80
                                      Host: cms.lucked.me
                         /admin /api /assets /bundles /uploaded │ everything else (/)
                                      ▼                          ▼
                     nginx ─► php-fpm (+ worker) ─► mysql   client app (22.11)
```

How it is wired: the project's `docker-compose.prod.yaml` was written for a standalone server and publishes its nginx as `${HTTP_PORT}:80`, with no Traefik labels. We do **not** edit the repo file and need no compose override: `HTTP_PORT=172.17.0.1:8081` publishes nginx on the docker0 gateway only (not on `0.0.0.0`, so it is not exposed and does not collide with Traefik), and a Traefik file-provider route (`infrastructure/dynamic/cms.yaml`) forwards the domain to it, exactly as for the `cloud` project.

Why one domain works without extra code: the Symfony app already serves everything under `/admin` (Sonata, elFinder) and `/api` (site API, JWT) itself, and its static files live under `/assets`, `/bundles` and `/uploaded`. Traefik only has to decide which container gets which path. A single name `cms.lucked.me` is one level deep, so the free Cloudflare Universal SSL certificate covers it (no paid certificate needed).

### 22.0 Requirements

- Steps 1–10 are done (Docker, `reverse-proxy` network, Traefik, `cloudflared` running) and steps 18.1/18.2 (tunnel and HTTPS-only settings) are in place.
- Step 11 (deploy key) is done. GitHub accepts a given public key as a Deploy key on **one** repository only, so the server needs its own key for `vtsot/cms-admin` (see 22.2).
- RAM: the image build runs webpack, so swap (step 6) must exist. Free disk: `df -h /home`.
- Traefik has the file provider and `extra_hosts: host.docker.internal` (step 19.1; shared with `cloud`).

### 22.1 Cloudflare: public hostname (browser)

Zero Trust → Networks → Tunnels → `vps` → **Published application routes** → **Add** (see 18.1 for the fields):

| Subdomain | Domain | Path | Type | URL |
|---|---|---|---|---|
| `cms` | `lucked.me` | empty | `HTTP` | `traefik:80` |

Leave **Path** empty: one route sends the whole domain to Traefik, and Traefik splits `/admin`, `/api` and `/` itself by the file-provider routes (22.4). Cloudflare creates the proxied CNAME record `cms` itself (delete an existing record named `cms` first). The HTTPS-only settings from 18.2 apply to the whole zone.

### 22.2 Clone the repository (server)

Create a separate key and an ssh host alias for this repository:

```bash
ssh-keygen -t ed25519 -C "dad@vps-main cms" -f ~/.ssh/id_ed25519_cms -N ""
cat ~/.ssh/id_ed25519_cms.pub            # add it: GitHub vtsot/cms-admin → Settings → Deploy keys (read-only)

cat >> ~/.ssh/config <<'CFG'
Host github-cms
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_cms
    IdentitiesOnly yes
CFG
chmod 600 ~/.ssh/config

ssh -T git@github-cms                    # "Hi vtsot/cms-admin! You've successfully authenticated"
cd /home/dad/workspace/www
git clone git@github-cms:vtsot/cms-admin.git cms
cd /home/dad/workspace/www/cms
```

(If the server's existing key is not used as a Deploy key anywhere else, you can skip the alias and clone with `git@github.com:vtsot/cms-admin.git`.)

> The project sets `name: cms-admin-prod` in its compose file, so containers and volumes are named `cms-admin-prod-*` whatever the folder is called. Do not change that name after the first start, or Docker creates new empty volumes (the database and the uploaded files would "disappear").

### 22.3 Secrets

```bash
cd /home/dad/workspace/www/cms
cp .env.prod.local.dist .env.prod.local
chmod 600 .env.prod.local

openssl rand -hex 32        # → APP_SECRET
openssl rand -hex 24        # → MYSQL_PASSWORD
openssl rand -hex 24        # → MYSQL_ROOT_PASSWORD

nano .env.prod.local
```

| Variable | Value |
|---|---|
| `APP_IMAGE` / `APP_TAG` | leave `cms-admin` / `latest` |
| `HTTP_PORT` | `172.17.0.1:8081`: nginx is published on the docker0 gateway only; Traefik reaches it there (22.4). Do not leave `80` (it collides with Traefik and bypasses ufw) |
| `RUN_MIGRATIONS` | `1`: migrations run when `php-fpm` starts |
| `MYSQL_DATABASE` / `MYSQL_USER` | `cms_admin` / `cms_admin` |
| `MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` | generated (`openssl rand -hex 24`: no characters that break the `DATABASE_URL`) |
| `APP_SECRET` | output of `openssl rand -hex 32` |
| `TIMEZONE` | `UTC` or `Europe/Kyiv` |
| `DEFAULT_URI` | `https://cms.lucked.me/` |
| `DEFAULT_LOCALE` / `LOCALES` | as in the dist file |
| `CORS_ALLOW_ORIGIN` | `^https://cms\.lucked\.me$` (the client and the API share one origin; add other origins with `\|` in the regex if other sites will call the API from a browser) |
| `MAILER_DSN` | `null://null` until a mail server is set up |
| `MESSENGER_TRANSPORT_DSN` | `doctrine://default?auto_setup=0` |

### 22.4 Traefik route (server)

No override file is needed. The stack's nginx publishes its port on the docker0 gateway (`HTTP_PORT=172.17.0.1:8081`, set in 22.3), and Traefik reaches it through the file provider, the same way as for `cloud` (step 19.1; the file provider, `extra_hosts` and the `./dynamic` volume are already in the Traefik compose file).

Check the docker0 address (use it in `HTTP_PORT` if it differs) and open the port for the docker networks only:

```bash
ip -4 addr show docker0 | grep inet                        # 172.17.0.1/16
sudo ufw allow from 172.16.0.0/12 to any port 8081 proto tcp
```

Create the route from the repo template (`docs/infrastructure/dynamic/cms.yaml`):

```bash
# on your machine
scp docs/infrastructure/dynamic/cms.yaml dad@100.91.57.78:/home/dad/workspace/infrastructure/dynamic/cms.yaml
# on the server: Traefik watches the folder, no restart needed
cd /home/dad/workspace/infrastructure && docker compose logs --tail 20 traefik   # no errors
```

```yaml
http:
  routers:
    cms:
      rule: Host(`cms.lucked.me`) && (Path(`/`) || PathPrefix(`/admin`) || PathPrefix(`/api`) || PathPrefix(`/assets`) || PathPrefix(`/bundles`) || PathPrefix(`/uploaded`))
      entryPoints: [web]
      service: cms
  services:
    cms:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:8081"
```

Routed: the admin, the API, their static files, and the exact path `/`. The app itself answers `/` with a redirect to `/admin` (`DefaultController`, route `web.homepage`), so no Traefik middleware is needed, and the redirect URL keeps the `https` scheme. There is no `redirectscheme` middleware and no certresolver: TLS and the redirect to https are done by Cloudflare. Router and service names must be unique among projects (step 20). When the client site takes `/` (22.11), remove ``Path(`/`) ||`` from the rule.

Check the stack file and the published port (run it in the project folder; every `docker compose` command for this project needs `-f docker-compose.prod.yaml --env-file .env.prod.local`: `-f` skips the dev compose files, `--env-file` feeds the `${...}` values, and the compose project name `cms-admin-prod` is fixed by the repo):

```bash
cd /home/dad/workspace/www/cms
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config > /dev/null && echo OK
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config | grep -A8 '^  nginx:' | grep -A2 ports      # published: 172.17.0.1:8081 -> 80, not 0.0.0.0
```

### 22.5 First start

```bash
cd /home/dad/workspace/www/cms
grep '^HTTP_PORT' .env.prod.local     # must be HTTP_PORT=172.17.0.1:8081, NOT 80 (the dist file has 80 and Traefik already uses it)
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d --build          # first build takes 5–15 minutes (composer + webpack inside the Dockerfile)
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local ps                     # php-fpm, nginx Up; mysql healthy
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local logs -f php-fpm        # migrations ran at start; Ctrl+C
```

The frontend is built inside the image (as for vacancy-grabber, step 14a); Node and Composer are not needed on the server. On a small VPS lower the Node heap: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local build --build-arg NODE_MAX_OLD_SPACE=1024`.

The queue worker is optional and is switched on with the `worker` profile; start it only if the project uses async messages:

```bash
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local --profile worker up -d
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local ps                     # messenger-worker Up
```

### 22.6 Administrator and first data

Look for a console command that creates a user: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm php bin/console list | grep -i -E 'user|admin'`. If there is none, either restore a database dump from your local machine (like step 17, "Restore", with `cms` instead of the long compose command):

```bash
scp cms-admin.sql.gz dad@100.91.57.78:/home/dad/workspace/backups/dump/
gunzip -c /home/dad/workspace/backups/dump/cms-admin.sql.gz | docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
```

or insert the user through `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec mysql mysql -uroot -p cms_admin`, with the password hash from `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm php bin/console security:hash-password`. Files uploaded through elFinder live in the `uploaded` volume; to copy existing ones into it: `docker cp ./uploaded/. cms-admin-prod-php-fpm-1:/var/www/html/public/uploaded/`.

### 22.7 Verify

```bash
# on the server (through Traefik, with the right Host header)
curl -sI -H 'Host: cms.lucked.me' http://127.0.0.1/admin/login | head -3   # 200, not 404
curl -sI -H 'Host: cms.lucked.me' http://127.0.0.1/api/doc      | head -3   # 401/200 from the app, not Traefik's 404

# from outside the tailnet
curl -sI http://cms.lucked.me/admin/        | head -3     # 301 to https (Cloudflare)
curl -sI https://cms.lucked.me/admin/login  | head -3     # 200, valid certificate
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cms.lucked.me/api/sites/auth/login   # 400/401/422 from the app (route exists), not 404
curl -sI https://cms.lucked.me/             | head -3     # main domain: 302 to /admin/ until 22.11
```

In the browser: `https://cms.lucked.me/admin` loads with styles, login works (cookies are Secure), an elFinder upload works and the file opens from `https://cms.lucked.me/uploaded/...`. `docker ps` must show no published port for the cms containers (only Traefik has `ports:`).

### 22.8 Updating

```bash
cd /home/dad/workspace/www/cms
git pull
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d --build          # migrations run automatically (RUN_MIGRATIONS=1)
docker image prune -f
```

### 22.9 Backups

Same pattern as step 17, plus the uploaded files. Create `/home/dad/workspace/backups/backup-cms.sh` (nano, or a heredoc with a delimiter other than `EOF`):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/dad/workspace/www/cms
STAMP=$(date +%F_%H%M)
docker compose -p cms-admin-prod -f docker-compose.prod.yaml --env-file .env.prod.local exec -T mysql \
  sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
  | gzip > /home/dad/workspace/backups/dump/cms-admin-$STAMP.sql.gz
# uploaded files (named volume cms-admin-prod_uploaded)
docker run --rm -v cms-admin-prod_uploaded:/src:ro -v /home/dad/workspace/backups/dump:/dst alpine \
  tar czf /dst/cms-admin-uploaded-$STAMP.tar.gz -C /src .
find /home/dad/workspace/backups/dump \( -name 'cms-admin-*.sql.gz' -o -name 'cms-admin-uploaded-*.tar.gz' \) -mtime +7 -delete
```

```bash
chmod 700 /home/dad/workspace/backups/backup-cms.sh
/home/dad/workspace/backups/backup-cms.sh && ls -lh /home/dad/workspace/backups/dump | tail -3
( crontab -l 2>/dev/null; echo '10 3 * * * /home/dad/workspace/backups/backup-cms.sh >> /home/dad/workspace/backups/backup.log 2>&1' ) | crontab -
```

`docker volume ls | grep cms-admin-prod` shows the exact volume names if the `uploaded` one differs.

### 22.10 Rollback / removal and troubleshooting

- Take the site offline only: delete the `cms` route in the tunnel (Zero Trust → Tunnels → `vps`), or `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local stop nginx`.
- Stop everything, keep data: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local down`.
- Full removal (**destroys the database and the uploads**; back up first): `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local down -v`, then `rm -rf /home/dad/workspace/www/cms`.

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik on `/admin` or `/api` | `dynamic/cms.yaml` is missing or has an error (`docker compose logs traefik` in `infrastructure/`), or the host is not `cms.lucked.me`. |
| `404 page not found` from Traefik on `/` | The router rule in `dynamic/cms.yaml` lacks ``Path(`/`)``: copy the rule from 22.4 (Traefik reloads the file itself). |
| Admin page without styles / broken images | `/assets`, `/bundles` or `/uploaded` is missing from the router rule in `dynamic/cms.yaml` (22.4). |
| `Bind for 0.0.0.0:80 failed: port is already allocated` | `HTTP_PORT` in `.env.prod.local` is still the dist value `80` (or a shell variable `HTTP_PORT` overrides it: `echo "$HTTP_PORT"` must be empty): set `HTTP_PORT=172.17.0.1:8081`, then `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d`. |
| `502` from Cloudflare | The tunnel route URL is not `http://traefik:80`, or the `cms` hostname is missing in the tunnel. |
| Links with `http://`, wrong client IP | `forwardedheaders.trustedips` is missing in Traefik (18.3). |
| Login redirects to a wrong host | `DEFAULT_URI` is not `https://cms.lucked.me/`; then `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d`. |
| `502`/`504` from Traefik on `/admin` | nginx is not up (`docker compose -f docker-compose.prod.yaml --env-file .env.prod.local ps`), `HTTP_PORT` is not the docker0 address (`ip -4 addr show docker0`), or ufw blocks 8081 (`sudo ufw allow from 172.16.0.0/12 to any port 8081 proto tcp`). |
| Build killed (137) / heap out of memory | Add swap (step 6), lower `NODE_MAX_OLD_SPACE` (22.5). |

### 22.11 The main domain root `https://cms.lucked.me/` (client website)

`https://cms.lucked.me/` is the public site that shows the content managed in the admin. It is a separate application (the `cms-client` repository, `git@github.com:vtsot/cms-client.git`) which talks to the API of the same domain, `https://cms.lucked.me/api` (its `CMS_ADMIN_API_AUTH_URL` / `CMS_ADMIN_API_CONTENT_URL` settings, `CMS_ADMIN_SITE_ID` and the site token/credentials come from the admin section).

> The client repository has **no production Dockerfile / compose file yet** (and depends on the local `cms-admin-client-bundle` package), so it cannot be started on the VPS the same way as the admin. Build a production image for it first (same pattern as `cms-admin`: `app` + `nginx` targets). Until then `/` is not routed.

When the client has its stack, put it in `/home/dad/workspace/www/cms/client` (own `docker-compose.prod.yaml`, own project name, its own `.env.prod.local`) and:

1. No new tunnel route: `cms.lucked.me` is already routed to Traefik (22.1).
2. Labels on the client's nginx service (unique names, `reverse-proxy` network, no `ports:`, no redirect, no certresolver). The low `priority` makes the admin route from `dynamic/cms.yaml` (22.4, longer rule) win for `/admin`, `/api`, `/assets`, `/bundles`, `/uploaded`; everything else goes to the client:
   ```yaml
   labels:
       - traefik.enable=true
       - traefik.docker.network=reverse-proxy
       - traefik.http.services.cms-client.loadbalancer.server.port=80
       - traefik.http.routers.cms-client.rule=Host(`cms.lucked.me`)
       - traefik.http.routers.cms-client.priority=1
       - traefik.http.routers.cms-client.entrypoints=web
   ```
   Caveat: the client's own static files must not live under `/assets`, `/bundles` or `/uploaded` (they would be sent to the admin); use another prefix such as `/build` or `/static`.
3. Its environment: `CLIENT_DOMAIN=cms.lucked.me`, `DEFAULT_URI=https://cms.lucked.me/`, `CMS_ADMIN_API_AUTH_URL=https://cms.lucked.me/api/sites/auth/`, `CMS_ADMIN_API_CONTENT_URL=https://cms.lucked.me/api/sites/<site id>/`. The client container reaches the API through the public name (Cloudflare), so no extra docker network is needed. Remove ``Path(`/`) ||`` from the router rule in `dynamic/cms.yaml` (22.4), so `/` goes to the client instead of the admin redirect.
4. Verify: `curl -sI https://cms.lucked.me/ | head -3`, and open a page that shows content from the admin.
