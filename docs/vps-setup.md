# VPS setup (Ubuntu 24.04) for multiple projects

A step-by-step guide for the **common part** of the server: clean VPS → Docker → shared **Traefik** reverse proxy → Cloudflare Tunnel. Every project has its own guide in `docs/projects/` (see the table below); do the common steps here first, then the guide of the project you want to deploy.

| Project | Guide | Public address |
|---|---|---|
| `vacancy-grabber` | [projects/vacancy-grabber.md](projects/vacancy-grabber.md) (steps 11–17 and the project part of 18) | `https://vacancy-grabber.lucked.me` |
| `cloud` (Nextcloud AIO) | [projects/cloud.md](projects/cloud.md) (step 19) | `https://cloud.lucked.me` |
| `cms` | [projects/cms.md](projects/cms.md) (step 22) | `https://cms.lucked.me`, `/admin`, `/api` |
| `tile-expert-test` | [projects/tile-expert-test.md](projects/tile-expert-test.md) (step 23) | `https://tile-expert-test.lucked.me` |
| `cv` (static files) | [projects/cv.md](projects/cv.md) (step 24) | `https://cv.lucked.me` |

The **step numbers are kept** across all files, so references such as "step 18.3" or "step 6" point to the same step wherever they appear. Later you can add more projects with their own domains to the same server (step 20).

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
    ├── cloud/                      # Nextcloud All-in-One (step 19)
    │   ├── docker-compose.yaml     # copy of docs/cloud/docker-compose.yaml
    │   ├── .env                    # NEXTCLOUD_DATADIR, APACHE_IP_BINDING, TAILSCALE_IP
    │   └── ncdata/                 # Nextcloud user data
    ├── cms/                        # git clone of vtsot/cms-admin (step 22); client app in cms/client (22.11)
    │   ├── docker-compose.traefik.yaml  # copy of docs/cms/docker-compose.traefik.yaml (Traefik labels, no ports)
    │   └── .env.prod.local         # secrets
    ├── tile-expert-test/           # git clone of LuckedMe/tile-expert-test (step 23)
    │   └── .env.prod.local         # secrets (APP_SECRET, MYSQL_*), chmod 600; the stack is docker-compose.prod.yaml from the repo (Traefik labels, no ports)
    └── cv/                         # static files only, no git (step 24)
        ├── docker-compose.yaml     # copy of docs/cv/docker-compose.yaml (nginx + Traefik labels)
        └── public/                 # cv.vitalii.sotnykov_ENG.pdf, index.html ...
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

> For the `cloud` project (step 19) one more rule is added: `sudo ufw allow from 172.16.0.0/12 to any port 11000 proto tcp` (Traefik reaches Nextcloud's Apache through the docker0 gateway). Projects that use Traefik labels (`cms`, `tile-expert-test`, `cv`) need no ufw rule. Never open 8080 or 11000 to the world.

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

## Step 18. Cloudflare Tunnel (shared by all public domains)

Goal: public domains (`vacancy-grabber.lucked.me`, `cloud.lucked.me`, `cms.lucked.me`, ...) are served over HTTPS and `http://…` redirects to `https://…`. This step is done **once** for the server (18.1–18.3); each project adds only its own public hostname. The project-specific part of this step (switching vacancy-grabber from the Tailscale IP to its domain) is in [projects/vacancy-grabber.md](projects/vacancy-grabber.md).

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

### 18.7 Security notes

- Nothing is exposed on the VPS for this: the tunnel is outbound only; the Traefik dashboard stays on `127.0.0.1:8080`.
- `TUNNEL_TOKEN` lives only in `/home/dad/workspace/infrastructure/.env` (chmod 600), never in git. If it leaks: Tunnels → `vps` → refresh the token, update `.env`, `docker compose up -d`.
- Later, optionally: Cloudflare WAF rate limiting rules and Bot Fight Mode for `/api/auth/login` and `/admin/login`.

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

## Step 21. Cheat sheet and troubleshooting (common part)

```bash
# Traefik
cd /home/dad/workspace/infrastructure && docker compose logs -f traefik
docker compose restart traefik

# resources
docker stats
df -h && docker system df
```

Project-specific commands and symptoms: [vacancy-grabber](projects/vacancy-grabber.md), [cloud](projects/cloud.md), [cms](projects/cms.md).

| Symptom | Cause / fix |
|---|---|
| `Gateway Timeout` | Traefik and nginx are in different networks. Check the `traefik.docker.network=reverse-proxy` label. |
| Cloudflare Error 1033 / tunnel `DOWN` | `cloudflared` is not running or the token is wrong: `cd /home/dad/workspace/infrastructure && docker compose logs cloudflared`. |
| `502` from Cloudflare | The public hostname service URL is not `http://traefik:80`, or `cloudflared` is not in the `reverse-proxy` network. |
| Endless redirect to https | A Traefik `redirectscheme` middleware is enabled on the router; remove it (Cloudflare does the redirect, step 18). |
| Everybody throttled as one IP, `http://` links in pages | `--entrypoints.web.forwardedheaders.trustedips` is missing in Traefik (step 18.3). |
| `http://` does not redirect to https | "Always Use HTTPS" is off in Cloudflare (step 18.2). |
| Certificate is not issued (variant B only) | DNS does not point to the VPS yet, or port 80 is closed. `dad.json` must have permissions `600`. See `docker logs traefik`. |
| `client version ... is too old` in Traefik logs | An old Traefik does not work with a new Docker. Update the image: `docker compose pull && docker compose up -d`. |
