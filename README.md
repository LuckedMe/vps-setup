# vps-setup

Step-by-step runbooks and deployment templates for one Ubuntu 24.04 VPS that hosts several projects behind a shared Traefik reverse proxy and a Cloudflare Tunnel. It is written for the server's owner and for anyone who has to rebuild or extend the server.

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)
![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)
[![Traefik](https://img.shields.io/badge/Traefik-v3.6-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](https://traefik.io/)
[![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare_Tunnel-cloudflared_2026.11.0-F38020?style=flat-square&logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
[![Tailscale](https://img.shields.io/badge/Tailscale-SSH_access-242424?style=flat-square&logo=tailscale&logoColor=white)](https://tailscale.com/)
[![Nginx](https://img.shields.io/badge/Nginx-stable--alpine-009639?style=flat-square&logo=nginx&logoColor=white)](https://nginx.org/)
[![Nextcloud AIO](https://img.shields.io/badge/Nextcloud-All--in--One-0082C9?style=flat-square&logo=nextcloud&logoColor=white)](https://github.com/nextcloud/all-in-one)
![Bash](https://img.shields.io/badge/Bash-scripts-4EAA25?style=flat-square&logo=gnubash&logoColor=white)

## Table of contents

- [What is in this repository](#what-is-in-this-repository)
- [Architecture](#architecture)
- [Hosted projects](#hosted-projects)
- [Tech stack](#tech-stack)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Usage and operations](#usage-and-operations)
- [Adding a new project](#adding-a-new-project)
- [Testing and validation](#testing-and-validation)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Documentation index](#documentation-index)
- [License](#license)

## What is in this repository

This is a documentation repository, not an application. It holds:

- the **common server guide**: clean VPS, hardening, Docker, Traefik and the Cloudflare Tunnel (steps 1–10, 18, 20, 21);
- one **guide per hosted project** (steps 11–17, 19, 22–24);
- **templates** that are copied to the server as they are: compose files, the Traefik file-provider route and `.env.dist` files;
- a helper script, [`docs/cloud/update_cloudflare_turn.sh`](docs/cloud/update_cloudflare_turn.sh), that renews Cloudflare TURN credentials for Nextcloud Talk.

Step numbers are the same in every file, so "step 18.3" always means the same thing.

## Architecture

The VPS has no public IP. It is reached over Tailscale for SSH and administration, and public domains are served through an outbound Cloudflare Tunnel.

```
Browser ──https──► Cloudflare edge (certificate, "Always Use HTTPS")
                        │  tunnel (outbound from the VPS)
                        ▼
                 cloudflared ──http──► traefik:80 ──► project containers
                                       (docker network "reverse-proxy")
```

- Cloudflare terminates HTTPS and redirects `http` to `https`. Traefik serves plain HTTP for tunnelled domains and must not have a `redirectscheme` middleware on them, otherwise the redirect loops.
- Only Traefik publishes ports (`80`, `443`, and the dashboard on `127.0.0.1:8080`). Projects use `expose:` and join the external `reverse-proxy` network; databases stay in the project's internal network.
- Every project is a separate `docker compose` stack in its own folder, routed by Traefik labels with unique router, service and middleware names.
- Nextcloud AIO is the exception: its Apache is published on the docker0 gateway and reached through the Traefik file provider ([`docs/infrastructure/dynamic/cloud.yaml`](docs/infrastructure/dynamic/cloud.yaml)).

## Hosted projects

| Project | What it is | Public address | Guide |
|---|---|---|---|
| `vacancy-grabber` | PHP application with worker and MySQL | `https://vacancy-grabber.lucked.me` | [docs/projects/vacancy-grabber.md](docs/projects/vacancy-grabber.md) |
| `cloud` | Nextcloud All-in-One | `https://cloud.lucked.me` | [docs/projects/cloud.md](docs/projects/cloud.md) |
| `cms` | Symfony + MySQL CMS (`/`, `/admin`, `/api`) | `https://cms.lucked.me` | [docs/projects/cms.md](docs/projects/cms.md) |
| `tile-expert-test` | Symfony JSON REST API with MySQL and Manticore | `https://tile-expert-test.lucked.me` | [docs/projects/tile-expert-test.md](docs/projects/tile-expert-test.md) |
| `cv` | Static files (CV PDF) served by nginx | `https://cv.lucked.me` | [docs/projects/cv.md](docs/projects/cv.md) |

## Tech stack

| Layer | Technology | Version | Purpose |
|---|---|---|---|
| OS | Ubuntu Server | 24.04 | Host system |
| Access | Tailscale, OpenSSH | n/a | Private SSH and admin access |
| Security | ufw, fail2ban, unattended-upgrades | distribution packages | Firewall, brute-force protection, security updates |
| Containers | Docker Engine + Compose plugin | official Docker repository | Runs every stack |
| Reverse proxy | Traefik | `v3.6` | Routing by `Host`, Docker and file providers |
| Tunnel | cloudflared | `2026.11.0` | Outbound tunnel to Cloudflare |
| Web server | nginx | `stable-alpine` | Static site (`cv`) |
| Cloud | Nextcloud All-in-One | `latest` (updates itself through its UI) | File sync and Talk |

Versions are taken from the compose files in [`docs/`](docs/).

## Quick start

Prerequisites: an Ubuntu 24.04 VPS with root SSH access, a Tailscale network, a Cloudflare account with a domain, and a local clone of this repository.

```bash
git clone <this repository> vps-setup
cd vps-setup
```

Then follow the guides in this order:

| Order | Steps | Where |
|---|---|---|
| 1. System, user, SSH, firewall, swap, Docker | 1–9 | [docs/vps-setup.md](docs/vps-setup.md) |
| 2. Shared network and Traefik | 10 | [docs/vps-setup.md](docs/vps-setup.md#step-10-shared-network-and-traefik) |
| 3. Cloudflare Tunnel | 18.1–18.3 | [docs/vps-setup.md](docs/vps-setup.md#step-18-cloudflare-tunnel-shared-by-all-public-domains) |
| 4. One or more projects | see the [table above](#hosted-projects) | [docs/projects/](docs/projects/) |

The core of the server (Traefik and the tunnel) comes from the template [`docs/infrastructure/docker-compose.yaml`](docs/infrastructure/docker-compose.yaml):

```bash
docker network create reverse-proxy
scp docs/infrastructure/docker-compose.yaml dad@<tailscale-ip>:/home/dad/workspace/infrastructure/
scp docs/infrastructure/.env.dist dad@<tailscale-ip>:/home/dad/workspace/infrastructure/.env
```

The first command runs on the server, the other two on your machine. Fill in `.env` on the server, then:

```bash
cd /home/dad/workspace/infrastructure
docker compose up -d
docker compose ps
```

`dad` is the server user and `<tailscale-ip>` is the Tailscale address of the VPS, as in the guides.

## Configuration

Real `.env` files live only on the server (`chmod 600`) and are never committed; only the `.dist` templates are in git. `docs/cloud/.env` is git-ignored.

| File on the server | Variable | Meaning | Secret |
|---|---|---|---|
| `infrastructure/.env` | `ACME_EMAIL` | Email for Let's Encrypt notifications | no |
| `infrastructure/.env` | `TUNNEL_TOKEN` | Cloudflare Tunnel token | **yes** |
| `www/cloud/.env` | `NEXTCLOUD_DATADIR` | Absolute path of Nextcloud user data; must exist before the first start and cannot change later | no |
| `www/cloud/.env` | `APACHE_IP_BINDING` | docker0 gateway address where AIO's Apache is published | no |
| `www/cloud/.env` | `TAILSCALE_IP` | Tailscale IP; the AIO admin UI (port 8080) is published only there | no |
| `www/cloud/.env` | `TURN_KEY_ID` | Cloudflare Realtime TURN key ID | no |
| `www/cloud/.env` | `TURN_API_TOKEN` | Cloudflare Realtime TURN API token | **yes** |

The `cms` and `tile-expert-test` projects keep their secrets in `.env.prod.local` in their own folders; see their guides for the variable lists.

## Usage and operations

Common commands on the server:

```bash
cd /home/dad/workspace/infrastructure
docker compose logs -f traefik        # Traefik logs
docker compose logs cloudflared | tail   # tunnel status
docker compose restart traefik
docker compose pull && docker compose up -d   # update images

docker stats
df -h && docker system df
```

The Traefik dashboard is bound to the server's localhost. Open it through an SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 dad@<tailscale-ip>
# then open http://localhost:8080
```

Renewing Cloudflare TURN credentials for Nextcloud Talk (installed in `www/cloud` on the server, run by cron every 12 hours; details in [docs/projects/cloud.md](docs/projects/cloud.md)):

```bash
./update_cloudflare_turn.sh
```

Per-project update, backup, rollback and removal commands are in the "Updating", "Backups" and "Rollback" sections of each project guide.

## Adding a new project

Step 20 of [docs/vps-setup.md](docs/vps-setup.md#step-20-adding-the-next-project) has the full example. The rules:

- unique router, service and middleware names in Traefik labels;
- no `ports:`, only `expose:` and the external `reverse-proxy` network;
- the database stays in the project's internal network;
- for a tunnelled domain, add a public hostname to the tunnel (service `HTTP`, URL `traefik:80`) and use no certificate labels and no redirect middleware.

## Testing and validation

There is no automated test suite or Makefile. Useful checks before copying a template to the server:

```bash
docker compose -f docs/infrastructure/docker-compose.yaml config -q   # needs ACME_EMAIL and TUNNEL_TOKEN set
bash -n docs/cloud/update_cloudflare_turn.sh
```

Smoke checks on the server and from outside the tailnet are in the "Verify" sections of the guides, for example `curl -I http://<tailscale-ip>` returns `404 page not found` when Traefik runs but has no route.

## Troubleshooting

The full table is in [step 21](docs/vps-setup.md#step-21-cheat-sheet-and-troubleshooting-common-part). The most common problems:

| Symptom | Cause and fix |
|---|---|
| `Gateway Timeout` | Traefik and the container are in different networks; check the `traefik.docker.network=reverse-proxy` label. |
| Cloudflare error 1033 or tunnel `DOWN` | `cloudflared` is not running or the token is wrong; check `docker compose logs cloudflared`. |
| `502` from Cloudflare | The tunnel route is not `http://traefik:80`, or `cloudflared` is not in the `reverse-proxy` network. |
| Endless redirect to https | A `redirectscheme` middleware is set on a tunnelled router; remove it. |
| `http://` links and one shared client IP | `--entrypoints.web.forwardedheaders.trustedips` is missing in Traefik. |

## Repository layout

```
.
├── README.md
└── docs/
    ├── vps-setup.md                 # common server guide (steps 1-10, 18, 20, 21)
    ├── projects/                    # one guide per project
    │   ├── vacancy-grabber.md
    │   ├── cloud.md
    │   ├── cms.md
    │   ├── tile-expert-test.md
    │   └── cv.md
    ├── infrastructure/              # Traefik + cloudflared templates
    │   ├── docker-compose.yaml
    │   ├── .env.dist
    │   └── dynamic/cloud.yaml       # Traefik file-provider route for Nextcloud
    ├── cloud/                       # Nextcloud AIO compose, .env.dist, TURN script
    ├── cms/docker-compose.traefik.yaml
    └── cv/docker-compose.yaml
```

## Documentation index

| Document | Content |
|---|---|
| [docs/vps-setup.md](docs/vps-setup.md) | Common server setup, Traefik, Cloudflare Tunnel, new projects, cheat sheet |
| [docs/projects/vacancy-grabber.md](docs/projects/vacancy-grabber.md) | Deploy, frontend build, backups, switch to the public domain |
| [docs/projects/cloud.md](docs/projects/cloud.md) | Nextcloud AIO, Talk and TURN |
| [docs/projects/cms.md](docs/projects/cms.md) | CMS deploy, Traefik labels, migration of the old setup |
| [docs/projects/tile-expert-test.md](docs/projects/tile-expert-test.md) | REST API deploy and backups |
| [docs/projects/cv.md](docs/projects/cv.md) | Static CV site |

## License

No license file is present in this repository.
