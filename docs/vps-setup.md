# VPS setup (Ubuntu 24.04) for multiple projects

A step-by-step guide: clean VPS → Docker → shared **Traefik** reverse proxy → the **vacancy-grabber** project. First the project is available at `http://<VPS Tailscale IP>`; then it is published at **`https://vacancy-grabber.lucked.me`** through a Cloudflare Tunnel (step 18). Step 19 adds a second project, **Nextcloud All-in-One** at `https://cloud.lucked.me`. Later you can add more projects with their own domains to the same server.

## How it works

```
Internet ──► :80 / :443 ──► Traefik (infrastructure)
                               │   docker network "reverse-proxy"
                               ├──► vacancy-grabber: nginx ─► php-fpm / worker ─► mysql
                               ├──► site1.com        (later)
                               └──► sub-1.site1.com  (later)
```

The VPS has **no public IP**: `100.91.57.78` is its Tailscale address, reachable only inside the tailnet (SSH, admin). Public domains go through a Cloudflare Tunnel, which is an outbound connection from the VPS to Cloudflare:

```
Browser ──https──► Cloudflare edge (certificate, "Always Use HTTPS")
                        │  tunnel (outbound from the VPS)
                        ▼
                 cloudflared ──http──► traefik:80 ──► nginx (Host: vacancy-grabber.lucked.me) ─► php-fpm / worker ─► mysql
```

With the tunnel, Cloudflare terminates HTTPS and redirects `http://` to `https://`; Traefik serves plain HTTP only (no Let's Encrypt, no redirect middleware for tunnelled domains).

- Only ports 80 and 443 are open to the outside, and only Traefik listens on them.
- Each project is a separate `docker compose` stack in its own folder. It is connected to Traefik through the `reverse-proxy` network and labels.
- Traefik obtains Let's Encrypt certificates for domains on its own and stores them in `letsencrypt/dad.json`.

### Directory structure on the server

```
/home/dad/workspace/
├── backups/                        # backup scripts (*.sh) + backup.log
│   └── dump/                       # archived DB dumps (*.sql.gz), kept 7 days
├── infrastructure/                 # Traefik
│   ├── docker-compose.yaml         # copy of vps-setup repo: docs/infrastructure/docker-compose.yaml
│   ├── .env                        # ACME_EMAIL, TUNNEL_TOKEN
│   ├── dynamic/cloud.yaml          # Traefik file-provider route for Nextcloud (step 19)
│   └── letsencrypt/
│       └── dad.json                # certificates (chmod 600)
└── www/
    ├── vacancy-grabber/            # git clone of the project
    └── cloud/                      # Nextcloud All-in-One (step 19)
        ├── docker-compose.yaml     # copy of docs/cloud/docker-compose.yaml
        ├── .env                    # NEXTCLOUD_DATADIR, APACHE_IP_BINDING, TAILSCALE_IP
        └── ncdata/                 # Nextcloud user data
    # later: site1.com/  site2.com/  sub-1.site1.com/ ...
```

In the examples below:
- `100.91.57.78` is the Tailscale IP of your VPS (replace it with yours);
- `vacancy-grabber.lucked.me` is the public domain (step 18);
- `dad` is the user on the server.

---

## Step 1. First login and system update

From your local computer:

```bash
ssh dad@100.91.57.78
```

On the server:

```bash
apt update && apt upgrade -y
timedatectl set-timezone UTC          # or Europe/Kyiv
hostnamectl set-hostname vps-main
reboot                                # if the kernel was updated
```

## Step 2. The `dad` user

Working as root is unsafe, so create a regular user with sudo:

```bash
adduser dad                           # set a password (needed for sudo)
usermod -aG sudo dad

# copy root's SSH key to the dad user
mkdir -p /home/dad/.ssh
cp /root/.ssh/authorized_keys /home/dad/.ssh/authorized_keys
chown -R dad:dad /home/dad/.ssh
chmod 700 /home/dad/.ssh
chmod 600 /home/dad/.ssh/authorized_keys
```

> If you log in to the server with a password and have no key yet, run this on your **local** computer:
> `ssh-keygen -t ed25519` (if you have no key), then `ssh-copy-id dad@100.91.57.78`.

**Without closing the current session**, check the login in a new terminal window:

```bash
ssh dad@100.91.57.78
sudo whoami                           # should print: root
```

## Step 3. SSH hardening

Do this only after key-based login as `dad` works.

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

sudo sshd -t && sudo systemctl restart ssh
```

Check the login `ssh dad@100.91.57.78` again in a **new** window. Only then close the old session.

## Step 4. Firewall (ufw)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

> The VPS has no public IP and the Cloudflare Tunnel (step 18) is outbound only, so ports 80/443 are not needed by the tunnel and are not reachable from the internet. They stay open as above (tailnet access, or a future public IP).

> For the `cloud` project (step 19) one more rule is added: `sudo ufw allow from 172.16.0.0/12 to any port 11000 proto tcp` (Traefik reaches Nextcloud's Apache through the docker0 gateway). Never open 8080 or 11000 to the world.

> ⚠️ Docker bypasses ufw rules for published ports (`ports:` in compose). That is why **only Traefik** has `ports:`. Projects use `expose:` and the `reverse-proxy` network. MySQL is not published to the outside.

## Step 5. fail2ban and automatic security updates

```bash
sudo apt install -y fail2ban unattended-upgrades
sudo systemctl enable --now fail2ban
sudo dpkg-reconfigure -plow unattended-upgrades   # answer "Yes"
sudo fail2ban-client status sshd
```

## Step 6. Swap

Building the frontend (webpack) inside Docker needs a lot of memory. On a VPS with 1–4 GB of RAM and no swap, the build fails with an OOM error.

```bash
free -h                                # check whether swap already exists
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf
sudo sysctl --system
free -h
```

## Step 7. Basic utilities

```bash
sudo apt install -y \
    curl \
    wget \
    git \
    make \
    nano \
    vim \
    unzip \
    zip \
    htop \
    ncdu \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    ufw \
    fail2ban \
    htop \
    mc \
    apache2-utils
```

## Step 8. Docker Engine + Docker Compose

Install from the official Docker repository. The `docker.io` package from the Ubuntu repository is outdated and not suitable.

```bash
# remove possible old packages
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt remove -y $pkg 2>/dev/null
done

# Docker key and repository
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

#echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
#https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
#  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# run docker without sudo
sudo usermod -aG docker dad

# for the changes to take effect:
newgrp docker

# configuring Docker to Start automatically
sudo systemctl enable docker
sudo systemctl enable containerd
```

Log out and log in again so the `docker` group takes effect:

```bash
exit
ssh dad@100.91.57.78

docker version
docker compose version
docker run --rm hello-world
```

Limit the size of container logs, otherwise they will fill the whole disk over time:

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
sudo systemctl restart docker
```

## Step 9. Directory structure

```bash
mkdir -p /home/dad/workspace/backups/dump
mkdir -p /home/dad/workspace/infrastructure/letsencrypt
mkdir -p /home/dad/workspace/infrastructure/dynamic
mkdir -p /home/dad/workspace/www
mkdir -p /home/dad/workspace/www/cloud/ncdata      # step 19 (Nextcloud AIO)

touch /home/dad/workspace/infrastructure/letsencrypt/dad.json
chmod 600 /home/dad/workspace/infrastructure/letsencrypt/dad.json
```

> Permissions `600` on `dad.json` are required. Otherwise Traefik refuses to work with the certificates.

## Step 10. Shared network and Traefik

The network is created once. Traefik sees all projects through it:

```bash
docker network create reverse-proxy
```

Create `docker-compose.yaml` for Traefik. Its content is in the `vps-setup` repo: [`docs/infrastructure/docker-compose.yaml`](infrastructure/docker-compose.yaml). There are two ways to copy it:
- copy the file from your machine: `scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/infrastructure/docker-compose.yaml dad@100.91.57.78:/home/dad/workspace/infrastructure/`;
- or right away, with `nano /home/dad/workspace/infrastructure/docker-compose.yaml` and pasting the content.

Email for Let's Encrypt:

```bash
cd /home/dad/workspace/infrastructure
echo 'ACME_EMAIL=you@example.com' > .env
```

Start it:

```bash
cd /home/dad/workspace/infrastructure
docker compose up -d
docker compose ps
docker compose logs -f traefik           # Ctrl+C to exit
```

In step 18 this same file gets the `cloudflared` service, the `--entrypoints.web.forwardedheaders.trustedips` flag and `TUNNEL_TOKEN` in `.env` (the project template already contains them).

Check: `curl -I http://100.91.57.78` should return `404 page not found`. This is expected: Traefik works, there are just no routes yet.

The Traefik dashboard is not open to the outside. You can view it through an SSH tunnel:

```bash
# on your local computer
ssh -L 8080:127.0.0.1:8080 dad@100.91.57.78
# then open http://localhost:8080 in the browser
```

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

## Step 18. Switching from the Tailscale IP to the public domain (Cloudflare Tunnel, HTTPS only)

Goal: `https://vacancy-grabber.lucked.me` is public, `http://…` redirects to `https://…`, and the stack in `/home/dad/workspace/www/vacancy-grabber` keeps running as it is (same folder, same database and volumes).

Why a tunnel: the VPS has no public IP (`100.91.57.78` is a Tailscale address), so a DNS A record and a Let's Encrypt certificate cannot work. `cloudflared` opens an outbound connection to Cloudflare, which serves the domain, terminates HTTPS and redirects `http` to `https`. The tunnel forwards plain HTTP to `traefik:80`.

> Do **not** enable a Traefik `redirectscheme` middleware for this domain. Every tunnel request reaches Traefik over plain HTTP, so it would redirect forever. The redirect is done by Cloudflare (18.2).

### 18.1 Cloudflare Zero Trust and the tunnel (browser)

1. Open https://one.dash.cloudflare.com and choose the account (first time: create a Zero Trust team name, plan **Free**).
2. Networks → Tunnels → **Create a tunnel** → type **Cloudflared** → name `vps` → Save.
3. Copy the **token** from the "Docker" install command (the long string after `--token`). Do not run the command it shows: the container is created in 18.3.
4. Click **Next**. The page with the route form is called **Published application routes** (older dashboards: **Public hostname**; you can also reach it later via Networks → Tunnels → `vps` → Edit → that tab). Add a route and fill in the form:

   | Field | Value | Meaning |
   |---|---|---|
   | **Subdomain** | `vacancy-grabber` | Only the label in front of the domain: type `vacancy-grabber`, without dots and without `.lucked.me`. |
   | **Domain** | `lucked.me` | Choose it from the drop-down (it lists the zones of your Cloudflare account). |
   | **Path** | empty | Leave it empty so the whole site goes through the tunnel. |
   | **Type** (service) | `HTTP` | The tunnel talks plain HTTP to Traefik; HTTPS is only between the browser and Cloudflare. |
   | **URL** | `traefik:80` | Container name and port on the `reverse-proxy` network; no `http://` prefix here. |

   Together Subdomain + Domain give the public address **`vacancy-grabber.lucked.me`**. Click **Save** (older dashboards: Save tunnel).

**How the subdomain is managed.** There is nothing to set up in DNS or at the registrar beforehand: a subdomain exists as soon as a DNS record with that name exists, and Cloudflare creates that record for you when you save the route: `vacancy-grabber` → `<tunnel-id>.cfargotunnel.com`, type CNAME, **Proxied** (orange cloud, it must stay proxied). Check it: dashboard → `lucked.me` → DNS → Records. Rules:
- Do not create an A or CNAME record for `vacancy-grabber` by hand. If one already exists, delete it first, otherwise Cloudflare reports that the record already exists and does not create the route.
- To change or remove the subdomain, edit or delete the route in the tunnel (Networks → Tunnels → `vps` → Edit), not the DNS record; delete a leftover record in DNS → Records if it stays behind.
- Another subdomain later (for example `api.lucked.me` or `vacancy-grabber-test.lucked.me`) is just another route on the same tunnel. The domain root `lucked.me` itself is a route with the **Subdomain** field left empty.

`traefik:80` is the Traefik container name on the `reverse-proxy` network. The original `Host` header (`vacancy-grabber.lucked.me`) is preserved, and that is what the Traefik router matches: the subdomain you enter here must be exactly the one in `APP_DOMAIN` (step 18.5).

### 18.2 Cloudflare HTTPS-only settings

Dashboard → `lucked.me` → SSL/TLS:

- Overview: encryption mode **Full** (not Flexible).
- Edge Certificates: **Always Use HTTPS = On** (this is the `http → https` 301 redirect, done at the Cloudflare edge), **Minimum TLS Version = 1.2**, **Automatic HTTPS Rewrites = On**.
- HSTS: leave it off for now; enable it only after https is verified (it is hard to undo).

### 18.3 Run cloudflared next to Traefik (server, SSH over Tailscale)

The template in the `vps-setup` repo [`docs/infrastructure/docker-compose.yaml`](infrastructure/docker-compose.yaml) already contains the `cloudflared` service and the Traefik flag `--entrypoints.web.forwardedheaders.trustedips=172.16.0.0/12`. Update the server copy:

```bash
# on your machine: copy the template to the server (nothing server-specific in it)
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/infrastructure/docker-compose.yaml dad@100.91.57.78:/home/dad/workspace/infrastructure/docker-compose.yaml

# on the server
cd /home/dad/workspace/infrastructure
echo 'TUNNEL_TOKEN=<token from 18.1>' >> .env
chmod 600 .env
docker compose up -d
docker compose ps                          # traefik and cloudflared Up
docker compose logs cloudflared | tail     # "Registered tunnel connection" (x4)
```

In the dashboard (Networks → Tunnels) the tunnel status must be **Healthy**.

> Without `trustedips`, Traefik replaces `X-Forwarded-Proto: https` with `http`: the app generates `http://` links and non-Secure cookies, and the real client IP is lost (the API rate limiter and login throttling would count everybody as one IP).

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

### 18.7 Security notes

- Nothing is exposed on the VPS for this: the tunnel is outbound only; the Traefik dashboard stays on `127.0.0.1:8080`.
- `TUNNEL_TOKEN` lives only in `/home/dad/workspace/infrastructure/.env` (chmod 600), never in git. If it leaks: Tunnels → `vps` → refresh the token, update `.env`, `docker compose up -d`.
- Later, optionally: Cloudflare WAF rate limiting rules and Bot Fight Mode for `/api/auth/login` and `/admin/login`.

### 18.8 Rollback

```bash
cd /home/dad/workspace/www/vacancy-grabber
cp /home/dad/workspace/backups/env.prod.local.ip-stage .env.prod.local
make prod-up                                                              # back to http://100.91.57.78 over Tailscale
cd /home/dad/workspace/infrastructure && docker compose stop cloudflared  # the domain goes offline (Cloudflare Error 1033)
```

### 18.9 Variant B: the VPS gets a public IP later

No tunnel is needed then. Create a DNS-only A record → the public IP (check with `dig +short vacancy-grabber.lucked.me`), uncomment the "Stage 2" labels (including the `redirectscheme` middleware) in `docker-compose.prod.yaml`, and `make prod-up`; Traefik obtains the Let's Encrypt certificate into `letsencrypt/dad.json`. Remove the tunnel public hostname and the `cloudflared` service so there are not two paths to the same site.

## Step 19. Project `cloud`: Nextcloud All-in-One (AIO)

Goal: Nextcloud at **`https://cloud.lucked.me`** (change the name if you want another), with optional Office (Collabora) and built-in backups, in `/home/dad/workspace/www/cloud`. It uses the same Traefik and the same Cloudflare Tunnel as vacancy-grabber. The AIO admin interface is **not** public: it is reachable only over Tailscale.

How AIO differs from a normal compose project:
- You run **one** container, the *mastercontainer*. It has access to the Docker socket and **creates and updates all the other containers itself** (apache, nextcloud, database, redis, collabora, borgbackup, ...). Do not describe them in your compose file and do not put them in `reverse-proxy`.
- Behind a reverse proxy AIO's Apache listens on port `11000` and speaks plain HTTP; TLS is done by Cloudflare.
- The container name `nextcloud-aio-mastercontainer` and the volume `nextcloud_aio_mastercontainer` are fixed by AIO: do not rename them.

```
Browser ──https──► Cloudflare ──tunnel──► cloudflared ──http──► traefik:80
                                  Host: cloud.lucked.me │ router from dynamic/cloud.yaml
                                                        ▼
                                  host.docker.internal:11000 (= 172.17.0.1, the docker0 gateway)
                                                        ▼
                                  nextcloud-aio-apache ─► nextcloud / database / redis / collabora ...

Admin UI (Tailscale only): https://100.91.57.78:8080 ─► nextcloud-aio-mastercontainer
```

### 19.0 Requirements and limits (read first)

- **RAM:** AIO wants 4 GB or more (8 GB is comfortable); the swap from step 6 must exist. **Disk:** user data lives in `ncdata/`; check `df -h /home`.
- **Cloudflare limits request bodies to 100 MB** (free and Pro plans). Larger files cannot be uploaded in the browser through `cloud.lucked.me`. The desktop and mobile clients upload in chunks and are not affected.
- Cloudflare's terms discourage serving large media through the proxy: fine for documents and photos, not for a video streaming service.
- **Nextcloud Talk** needs port `3478` (TURN, UDP and TCP), which cannot pass a Cloudflare tunnel, and the VPS has no public IP. Without a TURN server on a public IP, calls ring but cannot be answered. Either leave Talk unused or set up a TURN server: see 19.11.
- Docker Engine from step 8 is enough. Do not use the snap Docker.

### 19.1 Prepare Traefik for the host route (server)

The Traefik template in the repo already has what is needed: the file provider (`--providers.file.directory=/dynamic`), `extra_hosts: host.docker.internal:host-gateway`, the `./dynamic:/dynamic:ro` volume and `readTimeout=0` (so long uploads are not cut). The route itself is in [`docs/infrastructure/dynamic/cloud.yaml`](infrastructure/dynamic/cloud.yaml).

```bash
# on your machine
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/infrastructure/docker-compose.yaml dad@100.91.57.78:/home/dad/workspace/infrastructure/docker-compose.yaml
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/infrastructure/dynamic/cloud.yaml dad@100.91.57.78:/home/dad/workspace/infrastructure/dynamic/cloud.yaml

# on the server (if you changed the domain, edit it in dynamic/cloud.yaml first)
cd /home/dad/workspace/infrastructure
mkdir -p dynamic
docker compose up -d                       # recreates traefik with the new flags
docker compose logs traefik | tail         # no error lines
sudo ufw allow from 172.16.0.0/12 to any port 11000 proto tcp
```

The `ufw` rule is needed because Traefik reaches AIO through the docker0 gateway: that is host-local traffic, which `ufw` does filter (unlike published ports). Never open `8080` or `11000` to the world.

There is no `redirectscheme` middleware here (it would loop behind the tunnel); the `trustedips` flag from step 18.3 is what makes `X-Forwarded-Proto: https` reach Nextcloud.

### 19.2 Cloudflare: add the public hostname (browser)

Zero Trust → Networks → Tunnels → `vps` → **Published application routes** → **Add**: Subdomain `cloud`, Domain `lucked.me`, Type `HTTP`, URL `traefik:80`. Save. Cloudflare creates the proxied CNAME `cloud` → `<tunnel-id>.cfargotunnel.com` itself (see 18.1; delete an existing DNS record with that name first). The HTTPS-only settings from 18.2 apply to the whole zone, nothing more to do. Keep HSTS off in Cloudflare: Nextcloud sends its own header.

### 19.3 Files on the server

```bash
mkdir -p /home/dad/workspace/www/cloud/ncdata
cd /home/dad/workspace/www/cloud
```

Copy the templates from the repo ([`docs/cloud/docker-compose.yaml`](cloud/docker-compose.yaml), [`docs/cloud/.env.dist`](cloud/.env.dist)):

```bash
# on your machine
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/cloud/docker-compose.yaml dad@100.91.57.78:/home/dad/workspace/www/cloud/
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/cloud/.env.dist dad@100.91.57.78:/home/dad/workspace/www/cloud/

# on the server
cd /home/dad/workspace/www/cloud
cp .env.dist .env
chmod 600 .env
ip -4 addr show docker0                    # check the address; normally 172.17.0.1
nano .env                                  # TAILSCALE_IP, APACHE_IP_BINDING, NEXTCLOUD_DATADIR
```

Notes:
- `"${TAILSCALE_IP}:8080:8080"` publishes the admin UI only on the Tailscale address, so it is not reachable from the LAN or the internet, even if the VPS gets a public IP later. The UI uses a self-signed certificate: the browser warning is expected.
- `NEXTCLOUD_DATADIR` must be an existing absolute path **before the first start**; it cannot be changed later without reinstalling, and it must not be on a network drive. AIO sets the owner itself.
- `APACHE_IP_BINDING` must be the `docker0` address (`172.17.0.1` by default). Traefik's `host-gateway` resolves to the same address.
- Do **not** add `80:80` or `8443:8443`: those are only for AIO without a reverse proxy.
- `image: ...:latest` is what AIO recommends (it updates itself through its UI). Pin a tag only if you update by hand.

### 19.4 First start

```bash
cd /home/dad/workspace/www/cloud
docker compose up -d
docker compose ps                                       # nextcloud-aio-mastercontainer Up (healthy)
docker compose logs -f nextcloud-aio-mastercontainer    # wait until it is ready, Ctrl+C
```

### 19.5 Initial setup in the AIO interface (browser on a device in the tailnet)

1. Open `https://100.91.57.78:8080` (accept the certificate warning). The page shows a **passphrase** (8 words): **save it in a password manager now**. It is the only way into the admin UI. If it is lost: `docker exec nextcloud-aio-mastercontainer grep password /mnt/docker-aio-config/data/configuration.json`.
2. Log in with the passphrase. Under "New AIO instance" enter `cloud.lucked.me` and press **Submit domain**.
   - AIO checks the domain by requesting it from the VPS (through Cloudflare and the tunnel back to its own Apache). If it fails ("Domain does not point to this server"), set `SKIP_DOMAIN_VALIDATION: "true"` in `docker-compose.yaml`, run `docker compose up -d` and submit again. The check only protects against a mistyped domain; with a tunnel the DNS record is managed by Cloudflare.
3. Choose the optional containers. Recommended for a small VPS: **Nextcloud Office (Collabora)** only if there is RAM (about +1.5 GB); **ClamAV off**; **Fulltextsearch off**; **Imaginary on** (faster previews); **Talk off** unless you set up TURN (19.11).
4. Set the timezone (the one from step 1) and press **Download and start containers**. About 15 images are pulled; the first start takes 5-15 minutes. Wait until all containers are green and the **Open your Nextcloud** button appears. The page also shows the initial `admin` **password**: save it.
5. From outside the tailnet (a phone on mobile data) open `https://cloud.lucked.me`, log in as `admin`, change the password and create your own user.

### 19.6 After the installation

- Administration settings → **Overview**: go through the warnings. With a correct `trustedips` there should be none about HTTPS or reverse proxy headers.
- Trust Traefik as a proxy and check the settings:
  ```bash
  docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:set trusted_proxies 10 --value="172.16.0.0/12"
  docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:get overwriteprotocol   # https
  ```
  The client IP in Nextcloud's log should be the real one, not `172.x` (brute-force protection depends on it).
- Phone region: `docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:set default_phone_region --value="UA"` (your country code).
- Email: Administration → Basic settings → Email server (AIO has no mail server of its own).
- Clients: install the desktop and mobile apps with the server `https://cloud.lucked.me`.
- Optional: a Cloudflare WAF rate-limit rule for `/login` (like 18.7).

### 19.7 Backups (built-in Borg backup, separate from step 17)

1. On the server: `mkdir -p /home/dad/workspace/backups/nextcloud-aio` (not inside `ncdata/`).
2. AIO UI → **Backup and restore** → location `/home/dad/workspace/backups/nextcloud-aio` → **Create backup**. AIO shows a **backup encryption password**: save it in the password manager. Without it a restore is impossible.
3. Enable the **daily backup** (for example 04:00) in the same section. During the backup AIO stops the containers, checks the archive and starts them again; with "automatic updates" ticked it updates the containers at that time too.
4. A backup on the same disk is not a backup: copy `/home/dad/workspace/backups/nextcloud-aio` to another machine or storage (`rsync`/`rclone`). The AIO backup includes the data directory.
5. Test a restore once: AIO UI → Backup and restore → choose the backup → **Restore**. It also works after a reinstall: mount the same directory and enter the password.

### 19.8 Updates

- Containers (including Nextcloud major versions): AIO UI → **Update containers** (shown when new images exist), or the daily automatic updates from 19.7.
- The mastercontainer itself: `cd /home/dad/workspace/www/cloud && docker compose pull && docker compose up -d`. The UI shows a notice when it is outdated.
- Cleanup: `docker image prune -f`.

### 19.9 Verify

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep nextcloud               # all Up (healthy)
curl -s -o /dev/null -w '%{http_code}\n' http://172.17.0.1:11000/            # 200/302 from the host
curl -sI https://cloud.lucked.me/status.php | head -5                        # 200 (from a machine outside the tailnet)
curl -sI http://cloud.lucked.me/ | head -3                                   # 301 to https (Cloudflare)
```

`https://<LAN-or-public-address>:8080` must not answer: the admin UI listens only on the Tailscale IP. In the browser: log in, upload a 5 MB file, open it in Collabora (if enabled), create a share link and open it in a private window.

### 19.10 Rollback / removal

- Take the site offline only: delete the `cloud` route of the tunnel (Zero Trust → Tunnels → `vps`), or remove `dynamic/cloud.yaml` on the server.
- Stop AIO: AIO UI → **Stop containers**, then `docker compose down` in `www/cloud`. The data stays in `ncdata/` and in the volumes.
- Full removal (**destroys the data**; make a backup first): stop the containers in the UI, then
  ```bash
  cd /home/dad/workspace/www/cloud && docker compose down -v
  docker rm -f $(docker ps -aq --filter name=nextcloud-aio)
  docker volume rm $(docker volume ls -q --filter name=nextcloud_aio)
  docker network rm nextcloud-aio
  sudo rm -rf /home/dad/workspace/www/cloud/ncdata
  ```

### 19.11 Nextcloud Talk: incoming call is accepted on the phone but nothing happens

**Symptom.** The phone rings (the push notification works), you tap *Accept*, and the call never connects: no audio, endless "connecting".

**Cause.** The ringing and the signalling go over HTTPS (through Cloudflare, they work). The **audio/video itself is WebRTC, which is UDP/TCP traffic straight between the devices or through a TURN relay**, and that part cannot pass the Cloudflare tunnel (it carries only HTTP). Two phones on different mobile/Wi-Fi networks (NAT) almost never reach each other directly, so they need a TURN server. Here it fails for these reasons:

1. The VPS has **no public IP** (step "How it works"): nobody on the internet can reach port `3478` of the server, so the TURN of the AIO Talk container is unreachable.
2. The TURN host name is usually `cloud.lucked.me`, which in Cloudflare is **proxied (orange cloud / tunnel CNAME)** and points to Cloudflare, not to a TURN server. Cloudflare does not proxy `3478`.
3. If the server does get a public IP: `3478/tcp`+`3478/udp` are closed in the cloud firewall / router (NAT), `ufw`, or there is no port-forward to the VPS.
4. TURN has no `external-ip` (the server hands out its private address as the relay address), or the secret in Nextcloud differs from the one in the TURN server.

**Check first (2 minutes)**

```bash
# server: is the Talk part installed and what is configured
docker exec --user www-data nextcloud-aio-nextcloud php occ app:list | grep -i spreed
docker exec --user www-data nextcloud-aio-nextcloud php occ talk:turn:list
docker exec --user www-data nextcloud-aio-nextcloud php occ talk:stun:list
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -i talk          # AIO Talk: 3478->3478 tcp/udp
sudo ufw status verbose | grep -E '3478|5349'

# does the push reach the phone? (a call that rings means yes)
docker exec --user www-data nextcloud-aio-nextcloud php occ notification:test-push --user <your-nc-user>

# from a machine OUTSIDE the tailnet (phone on mobile data, another server):
nc -vzu <turn-host> 3478        # UDP: "succeeded" only means no ICMP refusal, so also run the browser test below
nc -vz  <turn-host> 3478        # TCP: must say "succeeded"
dig +short <turn-host>          # must be the real public IP of the TURN server, NOT a Cloudflare address (104.x / 172.67.x)
```

Browser test: open <https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/> and enter `turn:<turn-host>:3478`, the TURN username/password. Press *Gather candidates*: a line of type **`relay`** must appear. No `relay` candidate = the TURN is unreachable or the credentials are wrong; Nextcloud will not work either.

**Fix. Choose one variant.**

#### Variant A (recommended): a separate TURN server on a host with a public IP

The simplest reliable setup for a VPS behind a tunnel. TURN does not need much: a 1 vCPU / 512 MB VPS with a public IPv4 is enough (calls of a family: a few Mbit/s). Do **not** run it on the tunnelled VPS.

1. DNS in Cloudflare: **A record `turn` → public IP of the TURN host, "DNS only" (grey cloud)**. A proxied record will never work.
2. On the TURN host open the firewall (and the cloud provider's firewall, if there is one):
   ```bash
   sudo ufw allow 3478/tcp
   sudo ufw allow 3478/udp
   sudo ufw allow 5349/tcp               # TURN over TLS, optional (see below)
   sudo ufw allow 49160:49200/udp        # relay ports, must match min-port/max-port below
   ```
3. coturn in Docker (`/home/dad/workspace/turn/docker-compose.yaml`, `network_mode: host` is required, otherwise relaying through Docker NAT breaks):
   ```yaml
   name: turn
   services:
       coturn:
           image: coturn/coturn:latest
           container_name: coturn
           restart: unless-stopped
           network_mode: host
           volumes:
               - ./turnserver.conf:/etc/coturn/turnserver.conf:ro
   ```
   `/home/dad/workspace/turn/turnserver.conf` (generate the secret with `openssl rand -hex 32` and keep it in the password manager):
   ```ini
   listening-port=3478
   fingerprint
   use-auth-secret
   static-auth-secret=<SECRET>
   realm=turn.lucked.me
   # the PUBLIC IP of this host. If the host is itself behind NAT (a home router): <public-ip>/<private-ip>
   external-ip=<PUBLIC_IP>
   min-port=49160
   max-port=49200
   total-quota=100
   stale-nonce
   no-multicast-peers
   no-cli
   # do not let the relay reach private networks (SSRF protection); keep these lines
   denied-peer-ip=0.0.0.0-0.255.255.255
   denied-peer-ip=10.0.0.0-10.255.255.255
   denied-peer-ip=100.64.0.0-100.127.255.255
   denied-peer-ip=127.0.0.0-127.255.255.255
   denied-peer-ip=169.254.0.0-169.254.255.255
   denied-peer-ip=172.16.0.0-172.31.255.255
   denied-peer-ip=192.168.0.0-192.168.255.255
   ```
   ```bash
   cd /home/dad/workspace/turn && chmod 600 turnserver.conf && docker compose up -d && docker compose logs --tail 20 coturn
   ```
4. Tell Nextcloud to use it. Administration settings → **Talk** → *STUN servers*, *TURN servers*:
   - STUN: `turn.lucked.me:3478`
   - TURN: server `turn.lucked.me:3478`, secret = `<SECRET>`, protocol **UDP and TCP**.
   - Delete the old default entry `stun.nextcloud.com:443` only if you want everything private; keeping it as a second STUN is harmless.

   or by command:
   ```bash
   docker exec --user www-data nextcloud-aio-nextcloud php occ talk:stun:add turn.lucked.me:3478
   docker exec --user www-data nextcloud-aio-nextcloud php occ talk:turn:add turn turn.lucked.me:3478 udp,tcp --secret='<SECRET>'
   docker exec --user www-data nextcloud-aio-nextcloud php occ talk:turn:list
   ```
   If the Talk app is not installed (AIO option "Talk" is off): Apps → *Nextcloud Talk* → install, then do the settings above. If you enable the AIO **Talk** container as well (it brings its own signalling + TURN on port 3478), AIO overwrites these Talk settings: use either AIO's Talk with variant B or this external TURN with Talk **off** in AIO.
5. Click *Test* in Talk settings (it shows the result) and repeat the browser test above.
6. Optional: if some networks block UDP and non-standard ports (corporate Wi-Fi, some mobile operators), add TURN over TLS on `443`/`5349` with a certificate for `turn.lucked.me` (`tls-listening-port=5349`, `cert=`, `pkey=`) and a `turns:` entry in Talk. Most home and mobile networks work with `3478` only.

#### Variant B: the AIO Talk container (only when the VPS gets a public IP)

This is the built-in way and needs a **reachable** public address:

1. AIO UI → optional containers → **Talk** on → *Download and start containers*. Port `3478` (tcp+udp) is published by the Talk container directly on the host (not via Traefik/Cloudflare; the compose file has no `TALK_PORT`, the default `3478` is used).
2. Open the port: `sudo ufw allow 3478/tcp && sudo ufw allow 3478/udp`, and on the provider's firewall / router forward `3478` tcp+udp to the VPS (NAT).
3. The domain given to AIO (`cloud.lucked.me`) is used as the TURN name, so it must resolve to the public IP **without Cloudflare**. Use a separate grey-cloud A record and not the tunnel CNAME: create `turn.lucked.me → <public IP>` and set it as TURN/STUN host in Talk settings (as in variant A, step 4, secret from `occ talk:turn:list`).
4. With a pure tunnel and no public IP this variant **cannot work**: use variant A.

#### Variant D: Cloudflare Realtime TURN (ex "Cloudflare Calls"), no own TURN host

Cloudflare runs a global TURN/STUN service (anycast, `3478`, `53`, `80`, `443`, UDP/TCP/TLS), so it fits a VPS without a public IP and needs no server of your own. Free tier: 1000 GB/month of TURN traffic, then about $0.05/GB (check the current price in the dashboard). A family's calls use a few GB at most.

**How it fits Talk.** Cloudflare has no shared secret: you create a *key* and ask its API for short-lived credentials (`username` + `credential`, TTL up to 48 h). Talk supports this: an entry of the `spreed` app setting `turn_servers` may carry a static `username` and `password` (otherwise Talk derives them from `secret`). So a script fetches fresh credentials from Cloudflare and writes them into `turn_servers`; cron repeats it before they expire. The Talk settings page has no fields for this, only `occ` / the app config.

1. **Create the key** (browser): Cloudflare dashboard → *Realtime* (formerly *Calls*) → *TURN Server* → **Create**. Name it `nextcloud-turn`. Cloudflare shows a **TURN Token ID** (`TURN_KEY_ID`) and an **API Token** (`TURN_API_TOKEN`); the token is shown once: save both in the password manager. Never commit them and never put them into browser-side code.
2. **Check the API by hand** (any machine):
   ```bash
   curl -s -X POST \
     "https://rtc.live.cloudflare.com/v1/turn/keys/<TURN_KEY_ID>/credentials/generate-ice-servers" \
     -H "Authorization: Bearer <TURN_API_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"ttl": 172800}'
   ```
   The answer contains `iceServers` with `urls` (`stun:` and `turn:`/`turns:` on `turn.cloudflare.com`, ports `3478`, `53`, `80`, `443`, `5349`), `username` and `credential`. A `401` means a wrong key id / token.
3. **Verify a relay works**: open <https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/>, remove the default server, add `turn:turn.cloudflare.com:3478?transport=udp` with the generated `username` / `credential`, press *Gather candidates*: a **`relay`** line must appear.
4. **Install the update script on the server.** The repo has it as `docs/cloud/update_cloudflare_turn.sh`; it needs no extra packages (`curl`, `sed`, `docker`):
   ```bash
   # on your machine
   scp docs/cloud/update_cloudflare_turn.sh dad@100.91.57.78:/home/dad/workspace/www/cloud/
   # on the server: add the key to the existing .env of the project (see docs/cloud/.env.dist)
   cd /home/dad/workspace/www/cloud
   chmod +x update_cloudflare_turn.sh && chmod 600 .env
   echo 'TURN_KEY_ID=<id>'        >> .env
   echo 'TURN_API_TOKEN=<token>'  >> .env
   ./update_cloudflare_turn.sh
   ```
   The script requests credentials for 48 h and runs `occ config:app:set spreed turn_servers` with `[{"server":"turn.cloudflare.com:3478","username":...,"password":...,"protocols":"udp,tcp"}]` (`server` without a scheme). It **replaces the whole TURN list**.
5. **Check in Nextcloud**:
   ```bash
   docker exec --user www-data nextcloud-aio-nextcloud php occ config:app:get spreed turn_servers
   ```
   In Talk settings add the STUN server `stun.cloudflare.com:3478` (optional, TURN also answers STUN) and press *Test*.
6. **Renew by cron** (credentials live 48 h, renew every 12 h):
   ```bash
   crontab -e
   0 */12 * * * /home/dad/workspace/www/cloud/update_cloudflare_turn.sh >> /home/dad/workspace/www/cloud/turn-update.log 2>&1
   ```
   If the update stops working, calls start failing after at most 48 h; look at the log first.
7. Fully close and reopen Talk on both phones (ICE servers are cached) and run the 4 call tests from "After the fix".

Notes: do not enable the AIO **Talk** container together with this (AIO overwrites `turn_servers`). To stop using it: delete the key in the dashboard and `occ config:app:delete spreed turn_servers`. A single credential can be revoked with `POST .../credentials/revoke`.

#### Variant C: only people on the tailnet

If every participant has the Tailscale app, calls between tailnet devices need no TURN (devices reach each other by their `100.x` addresses), but Nextcloud/Talk still advertises the public name. This is fragile; do not use it as the main solution.

**After the fix**

- Fully close and reopen the Talk app on both phones (ICE servers are cached with the session).
- Test the 4 cases: Wi-Fi ↔ Wi-Fi (different networks), mobile data ↔ Wi-Fi, mobile ↔ mobile, and a call to a desktop browser.
- Coturn log (`docker compose logs -f coturn`) must show `ALLOCATE` / `session ... realm <turn.lucked.me> user <...>: incoming packet ALLOCATE processed, success` during a call. No lines at all = packets do not arrive (firewall/DNS/NAT); `401`/`Unauthorized` = the secret differs.

**Other causes of "Accept does nothing" (if relay candidates work)**

| Check | Fix |
|---|---|
| Android: Talk app is battery-restricted, notification shows but the app does not start the call | Settings → Apps → Talk → Battery: *Unrestricted*; allow *Display over other apps* and full-screen notifications. |
| Push works only sometimes | The server must reach `push-notifications.nextcloud.com` (outbound 443): `docker exec nextcloud-aio-nextcloud curl -sI https://push-notifications.nextcloud.com`. |
| Microphone/camera permission denied in the Talk app | App permissions on the phone. |
| Works for 1:1 but not for groups of 5+ | Without the High-Performance Backend (AIO Talk container with public IP, variant B) a mesh call is heavy; keep groups small. |
| Server clock is wrong (TURN secret check uses time) | `timedatectl` must show `System clock synchronized: yes` on **both** the TURN host and the VPS. |
| Cloudflare "Under attack"/Bot Fight blocks the app's polling | Check WAF events for `cloud.lucked.me/ocs/v2.php/apps/spreed/*`; skip the rule for the Nextcloud apps (user agents `Nextcloud-Talk`). |

## Step 20. Adding the next project

Example: `site1.com` in the folder `/home/dad/workspace/www/site1.com`.

```bash
cd /home/dad/workspace/www
git clone <repo> site1.com
```

In its `docker-compose`, on the web service (nginx / app):

```yaml
services:
    web:
        # ... image/build ...
        expose:
            - "80"
        labels:
            - traefik.enable=true
            - traefik.docker.network=reverse-proxy
            - traefik.http.services.site1.loadbalancer.server.port=80
            - traefik.http.routers.site1.rule=Host(`site1.com`) || Host(`www.site1.com`)
            - traefik.http.routers.site1.entrypoints=web
            - traefik.http.routers.site1.middlewares=site1-redirect
            - traefik.http.middlewares.site1-redirect.redirectscheme.scheme=https
            - traefik.http.routers.site1-https.rule=Host(`site1.com`) || Host(`www.site1.com`)
            - traefik.http.routers.site1-https.entrypoints=websecure
            - traefik.http.routers.site1-https.tls.certresolver=le
            - traefik.http.routers.site1-https.service=site1
        networks:
            - reverse-proxy
            - default

networks:
    reverse-proxy:
        external: true
```

For the subdomain `sub-1.site1.com` (folder `/home/dad/workspace/www/sub-1.site1.com`) everything is the same, with the rule ``Host(`sub-1.site1.com`)`` and its own router names.

Rules for every new project:
- **Unique names** for routers, services and middlewares in labels (`site1`, `sub1-site1`, …). The same names in two projects conflict.
- **No `ports:`.** Only `expose:` and the `reverse-proxy` network.
- **Each project's database stays in its internal network.** Only the web container joins `reverse-proxy`.
- **Folder name = compose project name.** Folders must differ, which is already the case because each domain has its own folder.
- **Only one project can answer on the IP.** The ``Host(`<IP>`)`` rule matches one router, so all other projects need domains (or subdomains). vacancy-grabber leaves the IP after step 18.
- **Tunnelled domains:** each new domain is one more **public hostname** on the same Cloudflare tunnel (service `HTTP`, URL `traefik:80`) plus the usual Traefik router labels: no certificate labels and no redirect middleware (Cloudflare redirects).
- Before starting, check that the domain's DNS already points to the server. Otherwise Let's Encrypt will not issue a certificate, and after several failed attempts it temporarily blocks requests.

## Step 21. Cheat sheet and troubleshooting

```bash
# Traefik
cd /home/dad/workspace/infrastructure && docker compose logs -f traefik
docker compose restart traefik

# project
cd /home/dad/workspace/www/vacancy-grabber
make prod-ps
make prod-logs
make prod-console
make prod-down

# Nextcloud AIO
cd /home/dad/workspace/www/cloud && docker compose ps
docker logs nextcloud-aio-mastercontainer      # also: nextcloud-aio-apache, nextcloud-aio-nextcloud
docker exec --user www-data -it nextcloud-aio-nextcloud php occ status

# resources
docker stats
df -h && docker system df
```

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik | The request `Host` does not match `APP_DOMAIN`, or the nginx container is not in the `reverse-proxy` network. Check: `docker inspect <container>` → Labels / Networks; Traefik dashboard. |
| `502 Bad Gateway` | nginx cannot reach php-fpm: `make prod-ps`, `make prod-logs`. |
| `Gateway Timeout` | Traefik and nginx are in different networks. Check the `traefik.docker.network=reverse-proxy` label. |
| Cloudflare Error 1033 / tunnel `DOWN` | `cloudflared` is not running or the token is wrong: `cd /home/dad/workspace/infrastructure && docker compose logs cloudflared`. |
| `502` from Cloudflare | The public hostname service URL is not `http://traefik:80`, or `cloudflared` is not in the `reverse-proxy` network. |
| Endless redirect to https | A Traefik `redirectscheme` middleware is enabled on the router; remove it (Cloudflare does the redirect, step 18). |
| Everybody throttled as one IP, `http://` links in pages | `--entrypoints.web.forwardedheaders.trustedips` is missing in Traefik (step 18.3). |
| `http://` does not redirect to https | "Always Use HTTPS" is off in Cloudflare (step 18.2). |
| Nextcloud: "Access through untrusted domain" | The domain is missing in `trusted_domains`: `docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:set trusted_domains 1 --value=cloud.lucked.me`. |
| Nextcloud: 502/504 from Traefik | AIO is stopped, `APACHE_IP_BINDING` is not the docker0 address, or `ufw` blocks port 11000 (19.1, 19.3). |
| Nextcloud: "Domain does not point to this server" in the AIO UI | Set `SKIP_DOMAIN_VALIDATION: "true"` (19.5). |
| Nextcloud: a big upload fails in the browser at 100 MB | Cloudflare body limit; use the sync client (19.0). |
| Nextcloud warns about reverse proxy headers / wrong client IPs | `trusted_proxies` (19.6) and `trustedips` in Traefik (18.3). |
| Talk: the call rings, *Accept* does nothing / endless connecting | No reachable TURN server (no public IP, Cloudflare-proxied name, closed `3478` tcp/udp): 19.11 (own coturn = variant A; Cloudflare Realtime TURN with a cron script = variant D). |
| AIO passphrase lost | `docker exec nextcloud-aio-mastercontainer grep password /mnt/docker-aio-config/data/configuration.json`. |
| Certificate is not issued (variant B only) | DNS does not point to the VPS yet, or port 80 is closed. `dad.json` must have permissions `600`. See `docker logs traefik`. |
| Build fails: `Killed` / exit 137 | Not enough memory, add swap (step 6). |
| Site without styles | The nginx image was built from old code: `make prod-up` (with `--build`). |
| `JavaScript heap out of memory` during the build | Webpack needs more memory: enable swap (step 6), lower `NODE_MAX_OLD_SPACE` (step 14a). |
| `yarn install` fails with a network/timeout error | Temporary registry problem: run `make prod-up` again (the timeout is already raised to 10 min). |
| `Your lockfile needs to be updated` | `package.json` was changed without updating `yarn.lock`: run `yarn install` locally, commit `yarn.lock`, then `git pull` on the server. |
| `client version ... is too old` in Traefik logs | An old Traefik does not work with a new Docker. Update the image: `docker compose pull && docker compose up -d`. |
