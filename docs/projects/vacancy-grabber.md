# Project `vacancy-grabber`

Symfony + MySQL project in `/home/dad/workspace/www/vacancy-grabber`. First it is available at `http://<VPS Tailscale IP>` (steps 11–17); then it is published at **`https://vacancy-grabber.lucked.me`** through the Cloudflare Tunnel (step 18).

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

## Step 11. Server access to the git repository

Create a separate key on the server and add it to the repository as a **Deploy key** (read-only):

```bash
ssh-keygen -t ed25519 -C "dad@vps-main" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Where to add the key:
- **GitHub:** repository → *Settings → Deploy keys → Add deploy key* (do not tick write access);
- **Bitbucket:** repository → *Repository settings → Access keys → Add key*.

Check:

```bash
ssh -T git@github.com            # or: ssh -T git@bitbucket.org
```

## Step 12. Clone the project

```bash
cd /home/dad/workspace/www
git clone git@github.com:vtsot/vacancy-grabber.git vacancy-grabber
# or: git clone git@bitbucket.org:vitalii-sotnykov/vacancy-grabber.git vacancy-grabber
cd /home/dad/workspace/www/vacancy-grabber
```

> The folder name `vacancy-grabber` becomes the compose project name and is used in container and volume names. Do not rename the folder after the first start, otherwise Docker creates new empty volumes for the database.

## Step 13. Project secrets

```bash
cd /home/dad/workspace/www/vacancy-grabber
cp .env.prod.dist .env.prod.local
chmod 600 .env.prod.local

# generate values
openssl rand -hex 32        # → APP_SECRET
openssl rand -base64 24     # → MYSQL_PASSWORD
openssl rand -base64 24     # → MYSQL_ROOT_PASSWORD
openssl rand -base64 24     # → JWT_PASSPHRASE

nano .env.prod.local
```

What to fill in:

| Variable | Value |
|---|---|
| `APP_DOMAIN` | server Tailscale IP, e.g. `100.91.57.78` (after step 18: `vacancy-grabber.lucked.me`) |
| `APP_SECRET` | output of `openssl rand -hex 32` |
| `DEFAULT_URI` | `http://100.91.57.78/` (after step 18: `https://vacancy-grabber.lucked.me/`) |
| `CORS_ALLOW_ORIGIN` | `'^https?://100\.91\.57\.78$'` (after step 18: `'^https://vacancy-grabber\.lucked\.me$'`) |
| `MYSQL_DATABASE` / `MYSQL_USER` | e.g. `vacancy_grabber` / `vacancy_grabber` |
| `MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` | generated passwords |
| `DATABASE_URL` | `mysql://vacancy_grabber:<MYSQL_PASSWORD>@mysql:3306/vacancy_grabber?serverVersion=8.0.32&charset=utf8mb4` |
| `JWT_PASSPHRASE` | generated string |

> If a password contains `@ : / ? # %`, those characters must be URL-encoded in `DATABASE_URL`. It is simpler to generate passwords without them: `openssl rand -hex 24`.

## Step 14. First project start

```bash
cd /home/dad/workspace/www/vacancy-grabber

make prod-up         # build images and start (first build takes 5–15 minutes)
make prod-ps         # all containers Up, mysql healthy
make prod-jwt-keys   # once: JWT keys in the "jwt" docker volume
make prod-migrate    # DB migrations + messenger queue tables
```

If `make` is not available, the same commands without it:

```bash
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d --build
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm php bin/console doctrine:migrations:migrate --no-interaction
```

**Administrator.** The project has no console command for creating a user. Options:
- move the database from your local machine (see step 17, "Restore");
- add the user directly to the users table through the MySQL console:
  ```bash
  docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec mysql \
    mysql -u root -p vacancy_grabber
  ```
  You can get a password hash with: `make prod-console` → `php bin/console security:hash-password`.

## Step 14a. Frontend build (yarn install && yarn build)

You do **not** need Node.js or yarn on the server. The frontend is built inside Docker, in the `assets` stage of the root `Dockerfile`:

1. `yarn install --frozen-lockfile` installs the packages from `yarn.lock`;
2. `yarn build` (`encore production`) compiles the assets into `public/assets/`;
3. the result is copied into both images: `app` (needs `entrypoints.json` / `manifest.json`) and `nginx` (serves the files).

This happens automatically on every `make prod-up` / `make prod-build`. Docker reuses the cached result when `package.json`, `yarn.lock`, `assets/` and `webpack.config.js` have not changed. The yarn download cache is also kept between builds, so after a dependency change packages are not downloaded again (this helps on a slow network; most of the install time is unpacking and linking).

Run **only** the frontend build, for example to check that it passes before restarting the stack:

```bash
cd /home/dad/workspace/www/vacancy-grabber
make prod-assets
```

The log must show `yarn install` and `encore production`, and end without `ERROR`.

Check that the compiled assets are in the running image:

```bash
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm ls public/assets | head
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec php-fpm cat public/assets/entrypoints.json | head -20
```

**Small VPS (1–2 GB RAM).** Webpack can run out of memory. Make sure swap is enabled (step 6) and lower the Node heap limit (default 2048 MB):

```bash
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local build --build-arg NODE_MAX_OLD_SPACE=1024
make prod-up
```

**Build from scratch** (if you suspect a broken cache):

```bash
docker builder prune -f
make prod-up
```

## Step 15. Check

```bash
curl -I http://100.91.57.78/           # 200 or 302 (redirect to login)
make prod-logs                          # logs of all containers
```

In the browser: `http://100.91.57.78/admin/source/list`. The page should open with styles.
Click "Grab" on a source. In `make prod-logs`, the `worker` container should show the message being processed.

## Step 16. Updating the project

```bash
cd /home/dad/workspace/www/vacancy-grabber
git pull
make prod-up
make prod-migrate
docker image prune -f                  # remove old images
```

`make prod-up` also rebuilds the frontend (`yarn install && yarn build`) when frontend files changed. No separate step is needed (see step 14a).

## Step 17. Database backups

Script `/home/dad/workspace/backups/backup-vacancy-grabber.sh`:

```bash
touch /home/dad/workspace/backups/backup-vacancy-grabber.sh
cat > /home/dad/workspace/backups/backup-vacancy-grabber.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /home/dad/workspace/www/vacancy-grabber
FILE=/home/dad/workspace/backups/dump/vacancy-grabber-$(date +%F_%H%M).sql.gz
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec -T mysql \
  sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
  | gzip > "$FILE"
find /home/dad/workspace/backups/dump -name 'vacancy-grabber-*.sql.gz' -mtime +7 -delete
EOF
chmod 700 /home/dad/workspace/backups/backup-vacancy-grabber.sh
/home/dad/workspace/backups/backup-vacancy-grabber.sh && ls -lh /home/dad/workspace/backups/dump
```

Cron (every day at 03:00):

```bash
( crontab -l 2>/dev/null; echo '0 3 * * * /home/dad/workspace/backups/backup-vacancy-grabber.sh >> /home/dad/workspace/backups/backup.log 2>&1' ) | crontab -
crontab -l
```

**Restore / move the local database to the server:**

```bash
# locally: make a dump and copy it to the server
# gzip -c vacancy_grabber.sql >> dump.sql.gz
scp dump.sql.gz dad@100.91.57.78:/home/dad/workspace/backups/dump/

# (to restore an automatic backup instead, pick a file here)
ls -lh /home/dad/workspace/backups/dump

# on the server, option 1: pipe the archive straight into mysql
cd /home/dad/workspace/www/vacancy-grabber
gunzip -c /home/dad/workspace/backups/dump/dump.sql.gz | docker compose -f docker-compose.prod.yaml --env-file .env.prod.local \
  exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
make prod-migrate

# on the server, option 2: interactive mysql console with SOURCE
# (the mysql container does not see host folders, so copy the file into it first)
cd /home/dad/workspace/www/vacancy-grabber
gunzip -k /home/dad/workspace/backups/dump/dump.sql.gz
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local cp \
  /home/dad/workspace/backups/dump/dump.sql mysql:/tmp/dump.sql
grep MYSQL_ROOT_PASSWORD .env.prod.local          # root password for the prompt
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec -it mysql mysql -uroot -p
#   mysql> USE vacancy_grabber;
#   mysql> SOURCE /tmp/dump.sql;
#   mysql> exit
docker compose -f docker-compose.prod.yaml --env-file .env.prod.local exec mysql rm /tmp/dump.sql
rm /home/dad/workspace/backups/dump/dump.sql
make prod-migrate
```

> It is better to also copy backups off the server (rsync / rclone to cloud storage).

## Step 18 (project part). Switching from the Tailscale IP to the public domain

Goal: `https://vacancy-grabber.lucked.me` is public, `http://…` redirects to `https://…`, and the stack in `/home/dad/workspace/www/vacancy-grabber` keeps running as it is (same folder, same database and volumes). The shared tunnel setup (18.1 tunnel and route, 18.2 HTTPS-only settings, 18.3 `cloudflared`, 18.7 security notes) is in [../vps-setup.md](../vps-setup.md#step-18-cloudflare-tunnel-shared-by-all-public-domains); do it first. In 18.1 the route for this project is Subdomain `vacancy-grabber`.

### 18.4 Back up before switching (server)

```bash
/home/dad/workspace/backups/backup-vacancy-grabber.sh && ls -lh /home/dad/workspace/backups/dump | tail -3
cp /home/dad/workspace/www/vacancy-grabber/.env.prod.local /home/dad/workspace/backups/env.prod.local.ip-stage
chmod 600 /home/dad/workspace/backups/env.prod.local.ip-stage
```

### 18.5 Switch the project to the domain (server)

```bash
cd /home/dad/workspace/www/vacancy-grabber
nano .env.prod.local
```

```
APP_DOMAIN=vacancy-grabber.lucked.me
DEFAULT_URI=https://vacancy-grabber.lucked.me/
CORS_ALLOW_ORIGIN='^https://vacancy-grabber\.lucked\.me$'
```

```bash
make prod-up      # recreates containers with the new env and the new Host() rule; the build is cached
make prod-ps
```

`APP_DOMAIN` feeds the Traefik rule ``Host(`vacancy-grabber.lucked.me`)`` on the plain `web` entrypoint. The "Stage 2" HTTPS labels in `docker-compose.prod.yaml` stay commented. No migrations and no new JWT keys are needed: same folder = same compose project = same volumes.

> After this, `http://100.91.57.78/` (Tailscale) stops answering, because the router now matches only the domain. To keep a private way in, set the rule in `docker-compose.prod.yaml` to ``Host(`${APP_DOMAIN}`) || Host(`100.91.57.78`)`` (optional).

### 18.6 Verify (from a machine that is not on the tailnet)

```bash
curl -sI http://vacancy-grabber.lucked.me/ | head -5     # 301, Location: https://vacancy-grabber.lucked.me/ (server: cloudflare)
curl -sI https://vacancy-grabber.lucked.me/ | head -5    # 200 or 302 to the login page, valid certificate (no -k)
```

In the browser (a phone on mobile data proves the site is public): `https://vacancy-grabber.lucked.me/admin/` logs in and the cookies are Secure. Click "Grab" on a source and check `make prod-logs`: the `worker` container processes the message.

Client IP check (the API rate limiter and login throttling use it): temporarily add `--accesslog.fields.headers.names.X-Forwarded-For=keep` to the Traefik `command:`, run `docker compose up -d`, open the site from the phone and make sure the logged `X-Forwarded-For` starts with the phone's public IP, not a Cloudflare or `172.x` address (`docker compose logs traefik | tail`). Remove the flag afterwards.

### 18.8 Rollback

```bash
cd /home/dad/workspace/www/vacancy-grabber
cp /home/dad/workspace/backups/env.prod.local.ip-stage .env.prod.local
make prod-up                                                              # back to http://100.91.57.78 over Tailscale
cd /home/dad/workspace/infrastructure && docker compose stop cloudflared  # the domain goes offline (Cloudflare Error 1033)
```

### 18.9 Variant B: the VPS gets a public IP later

No tunnel is needed then. Create a DNS-only A record → the public IP (check with `dig +short vacancy-grabber.lucked.me`), uncomment the "Stage 2" labels (including the `redirectscheme` middleware) in `docker-compose.prod.yaml`, and `make prod-up`; Traefik obtains the Let's Encrypt certificate into `letsencrypt/dad.json`. Remove the tunnel public hostname and the `cloudflared` service so there are not two paths to the same site.

### Cheat sheet

```bash
cd /home/dad/workspace/www/vacancy-grabber
make prod-ps
make prod-logs
make prod-console
make prod-down
```

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik | The request `Host` does not match `APP_DOMAIN`, or the nginx container is not in the `reverse-proxy` network. Check: `docker inspect <container>` → Labels / Networks; Traefik dashboard. |
| `502 Bad Gateway` | nginx cannot reach php-fpm: `make prod-ps`, `make prod-logs`. |
| Build fails: `Killed` / exit 137 | Not enough memory, add swap (step 6). |
| Site without styles | The nginx image was built from old code: `make prod-up` (with `--build`). |
| `JavaScript heap out of memory` during the build | Webpack needs more memory: enable swap (step 6), lower `NODE_MAX_OLD_SPACE` (step 14a). |
| `yarn install` fails with a network/timeout error | Temporary registry problem: run `make prod-up` again (the timeout is already raised to 10 min). |
| `Your lockfile needs to be updated` | `package.json` was changed without updating `yarn.lock`: run `yarn install` locally, commit `yarn.lock`, then `git pull` on the server. |
