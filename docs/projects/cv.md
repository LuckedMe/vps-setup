# Project `cv`: static files (CV pdf)

Static files only, in `/home/dad/workspace/www/cv`, public at `https://cv.lucked.me` (the main domain of the project). There is no application, no database and no GitHub repository: the server needs only a `public` folder with the files.

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

## Step 24. Install and operate

Goal: files from `/home/dad/workspace/www/cv/public` are served at `https://cv.lucked.me/<file name>`, for example `https://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf`, behind the same Traefik and the same Cloudflare Tunnel as the other projects.

```
Browser ──https──► Cloudflare ──tunnel──► cloudflared ──http──► traefik:80
                                 Host: cv.lucked.me │ router from the web labels
                                                    ▼
                                  nginx (container "web") ─► ./public (read-only)
```

How it is wired: one `nginx:stable-alpine` container (template: [`docs/cv/docker-compose.yaml`](cv/docker-compose.yaml)) mounts `./public` read-only and joins the external `reverse-proxy` network with Traefik labels (the step 20 pattern: router and service `cv`, entrypoint `web`, no redirect, no certresolver). It publishes no port, so there is no `ufw` rule and nothing to add to the Traefik folder. `cv.lucked.me` is one level deep, so the free Cloudflare Universal SSL certificate covers it.

Layout on the server:

```
/home/dad/workspace/www/cv/
├── docker-compose.yaml     # copy of docs/cv/docker-compose.yaml
└── public/                 # the only content: cv.vitalii.sotnykov_ENG.pdf, index.html, images ...
```

### 24.0 Requirements

Steps 1–10 are done (Docker, the `reverse-proxy` network, Traefik, `cloudflared` running) and steps 18.1/18.2 (tunnel and HTTPS-only settings) are in place. Nothing else: no swap, no deploy key, no secrets.

### 24.1 Cloudflare: public hostname (browser)

Zero Trust → Networks → Tunnels → `vps` → **Published application routes** → **Add** (see 18.1 for the fields):

| Subdomain | Domain | Path | Type | URL |
|---|---|---|---|---|
| `cv` | `lucked.me` | empty | `HTTP` | `traefik:80` |

Cloudflare creates the proxied CNAME record `cv` itself (delete an existing record with that name first).

### 24.2 Create the folder and start (server)

```bash
# on your machine: copy the compose file
ssh dad@100.91.57.78 'mkdir -p /home/dad/workspace/www/cv/public'
scp /home/vitaly/workspace/www/nastiksot-vps/vps-setup/docs/cv/docker-compose.yaml dad@100.91.57.78:/home/dad/workspace/www/cv/docker-compose.yaml

# on the server
cd /home/dad/workspace/www/cv
docker compose config -q && echo OK
docker compose up -d
docker compose ps                                  # web Up
```

If you want another domain, edit the ``Host(`cv.lucked.me`)`` rule in `docker-compose.yaml` first. Router and service names (`cv`) must be unique among projects (step 20).

### 24.3 Upload the files

From your machine (replace the paths with yours):

```bash
scp /home/vitaly/Documents/resume/cv.vitalii.sotnykov_ENG.pdf dad@100.91.57.78:/home/dad/workspace/www/cv/public/cv.vitalii.sotnykov_ENG.pdf
# a whole folder, removing files that no longer exist locally:
rsync -av --delete ./public/ dad@100.91.57.78:/home/dad/workspace/www/cv/public/
```

On the server the files must be readable by nginx (inside the container it runs as another user): directories `755`, files `644`.

```bash
chmod 755 /home/dad/workspace/www/cv/public
chmod 644 /home/dad/workspace/www/cv/public/*
```

The folder is mounted live: new and changed files are served at once, **no restart and no rebuild**.

`https://cv.lucked.me/` (the root) answers `403` while `public/` has no `index.html`. Either open the file URL directly (`https://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf`) or add a minimal page:

```bash
cat > /home/dad/workspace/www/cv/public/index.html <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>CV</title>
<p><a href="/cv.vitalii.sotnykov_ENG.pdf">Download my CV (PDF)</a></p>
HTML
chmod 644 /home/dad/workspace/www/cv/public/index.html
```

Tip: keep the file name stable (`cv.vitalii.sotnykov_ENG.pdf`) and replace the file, so the link never changes.

### 24.4 Verify

```bash
# on the server (through Traefik, with the right Host header)
curl -sI -H 'Host: cv.lucked.me' http://127.0.0.1/cv.vitalii.sotnykov_ENG.pdf | head -5        # 200, Content-Type: application/pdf

# from outside the tailnet
curl -sI http://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf  | head -3                            # 301 to https (Cloudflare)
curl -sI https://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf | head -5                            # 200, application/pdf, valid certificate
```

In the browser: `https://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf` opens the PDF. `docker ps` shows no published port for `cv-web-1`.

### 24.5 Updating

Replacing a file is just step 24.3 again. If you replaced `cv.vitalii.sotnykov_ENG.pdf` and still see the old one, Cloudflare serves it from its cache: Cloudflare dashboard → the `lucked.me` zone → Caching → Configuration → **Purge Cache** → Custom purge → the URL `https://cv.lucked.me/cv.vitalii.sotnykov_ENG.pdf` (or a Cache Rule with a short Edge TTL for this hostname). After changing the compose file: `docker compose up -d`; to update the nginx image: `docker compose pull && docker compose up -d && docker image prune -f`.

### 24.6 Backups

Nothing to back up on the server beyond the files themselves: keep the originals on your machine (or in the Nextcloud from step 19). To copy them back: `rsync -av dad@100.91.57.78:/home/dad/workspace/www/cv/public/ ./public/`.

### 24.7 Rollback / removal and troubleshooting

- Take the site offline only: delete the `cv` route in the tunnel (Zero Trust → Tunnels → `vps`), or `docker compose stop`.
- Stop and remove the container (files stay): `docker compose down`.
- Full removal: `docker compose down`, then `rm -rf /home/dad/workspace/www/cv` and delete the tunnel route.

| Symptom | Cause / fix |
|---|---|
| `404 page not found` from Traefik | The container is not running or not in the `reverse-proxy` network (`docker compose ps`, `docker compose config \| grep traefik`), or the Host is not `cv.lucked.me`. |
| `502`/`504` from Traefik | `web` is not up: `docker compose logs web`. |
| `502` from Cloudflare | The tunnel route URL is not `http://traefik:80`, or the `cv` hostname is missing in the tunnel. |
| `403 Forbidden` on `/` | No `index.html` in `public/` (24.3). On a file URL: the file or folder is not world-readable (`chmod 644` / `755`). |
| `404 Not Found` (nginx page) on a file | Wrong name or case (file names are case-sensitive: `CV.vitalii.sotnykov_ENG.pdf` ≠ `cv.vitalii.sotnykov_ENG.pdf`), or the file is not directly in `public/`. |
| `network reverse-proxy declared as external, but could not be found` | The shared infrastructure is not running (step 10): start Traefik or `docker network create reverse-proxy`. |
| Old file after replacing it | Cloudflare cache: purge the URL (24.5). |
