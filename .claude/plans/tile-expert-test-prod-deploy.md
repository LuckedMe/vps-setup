# Plan: production deployment of tile-expert-test to the VPS

## Context
The project is going to the production VPS described in `/home/vitaly/workspace/www/nastiksot-vps/vps-setup`
(Ubuntu, Docker, shared **Traefik** in the `reverse-proxy` network, **Cloudflare Tunnel** → `traefik:80`, no public IP,
Cloudflare does TLS and the http→https redirect; server user `dad`, ssh target `dad@100.91.57.78` over Tailscale;
projects live in `/home/dad/workspace/www/<name>`; public name `tile-expert-test.lucked.me`).

Today the repo has only a **development** stack (`docker-compose.yaml`, `.docker/*/Dockerfile`, code bind-mounted, dev DB
password). `vps-setup/docs/projects/tile-expert-test.md` (step 23) works around it with a server-only override. The sibling
projects `cms-admin.local` and `vacancy-grabber.local` already solved this with one pattern, which we reuse:

| Piece | Template to adapt |
|---|---|
| root multi-stage `Dockerfile` (`php-base` → `vendor` → `app` → `nginx`) | `cms-admin.local/Dockerfile` |
| `docker-compose.prod.yaml` + `.env.prod.local.dist` + `.dockerignore` | `cms-admin.local/` same names |
| Claude skill `main-dockerfile-fix` (`SKILL.md` + `scripts/check.sh`) | `vacancy-grabber.local/.claude/skills/main-dockerfile-fix/` (rule script F1–F8) and `cms-admin.local/.claude/skills/main-dockerfile-fix/` (workflow + doc) |
| skill instructions doc | `cms-admin.local/docs/main-dockerfile-fix.md` |
| `docs/deploy.md` | `cms-admin.local/docs/deploy.md` |
| `bin/deploy.sh` with `--remote` | `cms-admin.local/bin/deploy.sh` |

Decisions (confirmed with the user): Traefik reaches the stack through **labels on nginx + the external `reverse-proxy`
network** (no published ports, no ufw rule, no file on the server outside the project); the **vps-setup repo is updated**
too (step 23) so the two repos do not contradict each other. Nothing is committed or pushed; nothing is deployed to the real VPS
(the user does that) – everything is verified locally with a throw-away stack.

## What this app needs in production
php-fpm + nginx + MySQL 8 + **Manticore** (search index, volume); no Node/webpack, no uploads, no sessions, no worker
(`MESSENGER_TRANSPORT_DSN=sync://`). Migrations at php-fpm start (`RUN_MIGRATIONS=1`); the Manticore index is filled with
`bin/console app:order:reindex` (first deploy, or `deploy.sh --reindex`). `nelmio` Swagger UI needs `assets:install`
(`public/bundles`). Existing reusable files already in the repo: `.docker/php-fpm/docker-entrypoint.sh`
(cache warmup + migrations; has a stale `LOCALES` comment to fix), `.docker/php-fpm/config/php.prod.ini`
(`opcache.preload=config/preload.php`, which exists), `php-fpm.d/www.conf`, `nginx` configs, `mysql` Dockerfile/config.

## Steps

### 1. Production image and stack (project root)
- `Dockerfile` (new): stages `php-base` (php:8.4-fpm, `install-php-extensions @composer zip opcache intl pdo_mysql bcmath`, user `app`
  uid/gid 1000, php.ini + php-fpm.d + php.prod.ini, `APP_ENV=prod APP_DEBUG=0`), `vendor` (`composer install --no-dev --no-autoloader --no-scripts`,
  BuildKit cache mount, only manifests copied), `app` (`COPY . .`, `dump-autoload --no-dev --classmap-authoritative`,
  `post-install-cmd` for `assets:install`, remove `var/cache/prod`, create `var/{cache,log}` owned by `app`, entrypoint, `USER app:app`,
  `EXPOSE 9000`), `nginx` (nginx:mainline-alpine, configs, `public/` from `app`), final `FROM app` so `app` stays the default target.
- `.dockerignore` (new): `.git .idea vendor var tests docs .claude .docker/mysql/data docker-compose*.yaml .env.local .env.*.local config/secrets/prod/prod.decrypt.private.php .php-cs-fixer* .phpunit.cache`.
- `docker-compose.prod.yaml` (new, `name: tile-expert-test-prod`): `php-fpm` (build target `app`, `env_file: .env.prod.local`, `DATABASE_URL` from `MYSQL_*`,
  `MANTICORE_URL=http://manticore:9308`, `RUN_MIGRATIONS`, depends on healthy mysql), `nginx` (image+build target `nginx`, **no `ports`**, networks
  `app` + external `reverse-proxy`, Traefik labels: `traefik.enable`, `docker.network=reverse-proxy`, service port 80, router
  ``Host(`${APP_DOMAIN}`)``, entrypoint `web`, no redirect, no certresolver), `mysql` (build `./.docker/mysql`, volume, `tmpfs` over the dev init.sql, healthcheck),
  `manticore` (pinned image, volume). No adminer. Named volumes `mysql`, `manticore`.
- `.env.prod.local.dist` (new, placeholders `!ChangeMe!` only): `APP_IMAGE`, `APP_TAG`, `MANTICORE_VERSION`, `RUN_MIGRATIONS`, `MYSQL_*`, `APP_SECRET`,
  `TIMEZONE`, `APP_DOMAIN`, `DEFAULT_URI`, `CORS_ALLOW_ORIGIN`, `PRODUCT_*`. Real file `.env.prod.local` is git-ignored (`/.env.*.local` already matches).
- `.docker/php-fpm/docker-entrypoint.sh`: drop the stale cms-specific `LOCALES` comment (keep warmup + `RUN_MIGRATIONS`).

### 2. Skill `main-dockerfile-fix` + instructions
- `.claude/skills/main-dockerfile-fix/SKILL.md` – description (when to trigger), rule table, procedure (run script → triage → smallest edit → re-run → verify build → report, do not commit).
- `.claude/skills/main-dockerfile-fix/scripts/check.sh` – adapted from the vacancy-grabber script: F1 PHP version vs composer/dev compose, F2 extensions
  (composer `ext-*`, `pdo_mysql`; dev-only extensions such as gd/exif/xsl/amqp/redis/pcov/excimer reported as INFO), F4 COPY sources exist, F5 compose targets are stages,
  F6 `.dockerignore` excludes secrets/heavy paths, F7 non-root `USER`, `APP_ENV=prod`, `--no-dev`; **F3/F8 (Node/assets) removed**; new **F9** prod compose sanity
  (`nginx`/`mysql`/`manticore` without `ports`, nginx in `reverse-proxy`, every `${VAR}` without default exists in `.env.prod.local.dist`, no non-placeholder secrets in the dist file).
- `docs/main-dockerfile-fix.md` – detailed instructions (what the VPS expects, reference layout of the Dockerfile, audit checklist, fix procedure, verification commands, troubleshooting), written like the cms one but for this app.

### 3. Deployment guide `docs/deploy.md`
Sections: architecture; prerequisites (server + local); Cloudflare public hostname `tile-expert-test.lucked.me` → `HTTP traefik:80`; clone with a dedicated deploy key
(`github-tile-expert-test` alias, repo `LuckedMe/tile-expert-test`); `.env.prod.local` (generate `APP_SECRET`, `MYSQL_*` with `openssl rand -hex`, table of every variable);
first start (`docker compose -f docker-compose.prod.yaml --env-file .env.prod.local up -d --build`, migrations, `app:order:reindex`); verify (inside the server through Traefik with a Host header, and from outside);
updating (`bin/deploy.sh`, **`bin/deploy.sh --remote`**, options and env vars table, rollback with `--ref`); backups (mysqldump script + cron, Manticore is rebuilt, not backed up) and restore; stop/remove;
troubleshooting table (404 from Traefik, 502, `reverse-proxy` network missing, empty search, build killed 137, `tile.expert` 403 limitation); quick reference.

### 4. `bin/deploy.sh` (adapted from the cms script)
Runs ON THE SERVER, or from the dev machine with `--remote` (ssh to `DEPLOY_HOST`, default `dad@100.91.57.78`, cd `DEPLOY_DIR`
`/home/dad/workspace/www/tile-expert-test`, runs the server's copy with the same options, warns about unpushed commits, forwards `BACKUP_SCRIPT`/`APP_URL` set locally).
Options: `--ref`, `--no-pull`, `--no-prune`, `--no-backup`, **`--reindex`** (rebuild the Manticore index after the update), `--remote`, `--host`, `--dir`, `--help`.
Steps: preflight (docker, compose plugin, compose file, `.env.prod.local`, no `!ChangeMe!`) → `compose config` → clean tree check → `git fetch` + `pull --ff-only` / `--ref` →
backup (`BACKUP_SCRIPT`, warn if missing) → `up -d --build --remove-orphans` → wait for `php-fpm nginx mysql manticore` running → show php-fpm log → optional reindex →
`curl` `APP_URL` (default `https://tile-expert-test.lucked.me/api/doc`, 2xx/3xx, empty = skip) → `image prune`. `set -Eeuo pipefail`, error trap, executable bit.

### 5. Project docs and plans
- `makefile`: `prod-deploy` (`bin/deploy.sh`), `prod-deploy-remote` (`--remote`), `prod-build`, `prod-up`, `prod-down`, `prod-ps`, `prod-logs`, `prod-console`, `prod-reindex`; `.PHONY` + `make help` text.
- `README.md`: new "Deployment" section (what is in the prod stack, links to `docs/deploy.md` and `docs/main-dockerfile-fix.md`, the skill, `bin/deploy.sh [--remote]`), the new make targets described in the "Make targets" tables, project structure and documentation lists.
- `docs/technical-specifications.md`: new section "Production deployment" with checkboxes for every deliverable above (ticked as they are done); `.claude/plans/` plan file = this file.

### 6. vps-setup repo (uncommitted edits)
- `docs/projects/tile-expert-test.md` (step 23): rewrite to the new flow – Cloudflare hostname (unchanged), clone (unchanged), secrets from `.env.prod.local.dist`, first start with `docker-compose.prod.yaml`,
  verify, updating via `bin/deploy.sh [--remote]`, backups script using the prod compose, troubleshooting; remove the "override" / "dev compose" explanation and the `!reset` Docker-version requirement.
- Delete `docs/tile-expert-test/docker-compose.override.yaml` and `.env.local.dist` (superseded by the files in the project repo); fix their references in `docs/vps-setup.md` (directory tree, project table).
- Copy this plan to `vps-setup/.claude/plans/tile-expert-test-prod-deploy.md` (project convention).

## Files
New: `Dockerfile`, `.dockerignore`, `docker-compose.prod.yaml`, `.env.prod.local.dist`, `bin/deploy.sh`, `docs/deploy.md`, `docs/main-dockerfile-fix.md`,
`.claude/skills/main-dockerfile-fix/{SKILL.md,scripts/check.sh}`. Changed: `makefile`, `README.md`, `docs/technical-specifications.md`, `.docker/php-fpm/docker-entrypoint.sh`.
vps-setup: `docs/projects/tile-expert-test.md`, `docs/vps-setup.md`, removed `docs/tile-expert-test/*`, new plan copy.
Dev stack (`docker-compose.yaml`, `.docker/*/Dockerfile`, `docker-compose.override.yaml*`) stays untouched.

## Verification (all local, throw-away)
1. `bash .claude/skills/main-dockerfile-fix/scripts/check.sh` exits 0; run it against a deliberately broken copy (missing extension, no `.dockerignore`, `USER root`) to see that rules fire.
2. `docker build --check .`; `docker build --target app -t tile-expert-test:test .` and `--target nginx`; `docker run --rm tile-expert-test:test php bin/console about` → `prod`, debug false; `ls public/bundles` has nelmio assets; `composer show` has no dev packages.
3. Throw-away `.env.prod.local` (random secrets, `APP_DOMAIN=localhost`) + a scratch override publishing nginx on `127.0.0.1:18080`: `docker compose -f docker-compose.prod.yaml --env-file .env.prod.local config`,
   `up -d --build`, migrations ran, `curl :18080/api/doc` 200, `POST /api/orders` 204, `GET /api/orders` and `?query=` return the order after `app:order:reindex`, `GET /api/orders/{id}` 200, `docker compose ... ps` shows no published ports in the real file; `down -v`, delete the env file.
4. `bin/deploy.sh --help`, `bash -n`, `shellcheck` if installed; run `bin/deploy.sh --no-pull --no-backup` against the throw-away stack; run `--remote` with a fake `ssh` on `PATH` to check the command it would run (host, dir, quoted options) – no real server contact.
5. `php bin/phpunit` still green (dev stack untouched), `git status` shows only the intended files.
6. vps-setup: grep for stale references (`docker-compose.override.yaml`, `.env.local`, `!reset`) in the tile-expert-test docs.
