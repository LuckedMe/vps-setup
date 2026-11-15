# Project `cloud`: Nextcloud All-in-One

Nextcloud AIO in `/home/dad/workspace/www/cloud`, public at `https://cloud.lucked.me`; the AIO admin UI is reachable only over Tailscale.

> Prerequisite: the common server setup, [../vps-setup.md](../vps-setup.md) (steps 1–10 and the Cloudflare Tunnel, step 18.1–18.3). Step numbers are the same as in that file.

## Step 19. Install and operate

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

### Cheat sheet

```bash
cd /home/dad/workspace/www/cloud && docker compose ps
docker logs nextcloud-aio-mastercontainer      # also: nextcloud-aio-apache, nextcloud-aio-nextcloud
docker exec --user www-data -it nextcloud-aio-nextcloud php occ status
```

| Symptom | Cause / fix |
|---|---|
| Nextcloud: "Access through untrusted domain" | The domain is missing in `trusted_domains`: `docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:set trusted_domains 1 --value=cloud.lucked.me`. |
| Nextcloud: 502/504 from Traefik | AIO is stopped, `APACHE_IP_BINDING` is not the docker0 address, or `ufw` blocks port 11000 (19.1, 19.3). |
| Nextcloud: "Domain does not point to this server" in the AIO UI | Set `SKIP_DOMAIN_VALIDATION: "true"` (19.5). |
| Nextcloud: a big upload fails in the browser at 100 MB | Cloudflare body limit; use the sync client (19.0). |
| Nextcloud warns about reverse proxy headers / wrong client IPs | `trusted_proxies` (19.6) and `trustedips` in Traefik (18.3). |
| Talk: the call rings, *Accept* does nothing / endless connecting | No reachable TURN server (no public IP, Cloudflare-proxied name, closed `3478` tcp/udp): 19.11 (own coturn = variant A; Cloudflare Realtime TURN with a cron script = variant D). |
| AIO passphrase lost | `docker exec nextcloud-aio-mastercontainer grep password /mnt/docker-aio-config/data/configuration.json`. |
