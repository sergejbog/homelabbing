# Self-Hosted Homelab

A production-grade homelab running 28 self-hosted services on a single server, managed via GitOps with automated secrets injection, TLS termination, and scheduled backups.

## Architecture

```
                  Internet
                     │
              ┌──────▼──────┐
              │   Traefik   │  ← Reverse proxy + Let's Encrypt TLS
              └──────┬──────┘
                     │
         ┌───────────┼───────────┐
         │           │           │
    ┌────▼────┐ ┌────▼────┐ ┌───▼─────┐
    │ Service │ │ Service │ │ Service │  ← Docker Compose stacks
    └─────────┘ └─────────┘ └─────────┘
         │
    ┌────▼──────┐     ┌─────────────┐
    │ Infisical │     │   Komodo    │  ← Secrets manager + Deploy orchestrator
    └───────────┘     └─────────────┘
```

**Key design decisions:**
- Each service lives in its own `services/<name>/` directory with a `docker-compose` file
- Secrets are **never stored in this repo** — injected at deploy time via [Infisical](https://infisical.com/)
- [Komodo](https://komo.do/) orchestrates deployments and syncs state from this repo (`main.toml`)
- [Traefik](https://traefik.io/) handles routing and automatic TLS certificates via Let's Encrypt
- Encrypted offsite backups to Backblaze B2 via [Restic](https://restic.net/)

## Services

Each service has its own directory under `services/` with a self-contained `docker-compose` file. Browse [`services/`](./services) for the full list.

## Secrets Management

Secrets are fetched from Infisical before each deployment and cleaned up after:

```
deploy → fetch-secrets-pre-deploy.sh → docker compose up → cleanup-secrets-post-deploy.sh
```

Each service has a corresponding secret path in Infisical. No credentials ever touch this repository or the filesystem beyond the deploy lifecycle.

See `scripts/` for the full deployment and backup workflow.

## Backup Strategy

- **What**: All service data volumes and databases
- **Where**: Backblaze B2 (encrypted with Restic)
- **When**: Daily at 01:10 via cron
- **Notifications**: Backup status sent via Apprise to ntfy

Services and their retention policies are declared in `scripts/backup-config.yml`. The crontab is in `scripts/my-crontab.txt` — load it with:

```bash
crontab scripts/my-crontab.txt
```

See `scripts/BACKUP-GUIDE.md` for full setup and restore instructions.

## Bootstrap / Disaster Recovery

The stack has a specific bring-up order because most services depend on Infisical for their secrets, and Infisical itself needs to be running first. Three `.env` files are required before anything can start — they are gitignored and must be created from their `.example` counterparts.

### 1. Fill in the required `.env` files

```bash
cp scripts/.env.example scripts/.env
cp services/infisical/.env.example services/infisical/.env
cp services/traefik/.env.example services/traefik/.env
# Edit each file with your real values
```

| File | What it contains |
|---|---|
| `scripts/.env` | Infisical client credentials + Restic/B2 backup credentials |
| `services/infisical/.env` | Infisical server config (DB password, JWT secret, SMTP, etc.) |
| `services/traefik/.env` | Domain name, Let's Encrypt email, WireGuard peer IP, basic auth hash |

### 2. Start Infisical

```bash
# If recovering: restore the Infisical database from Restic first
# export RESTIC_REPOSITORY / RESTIC_PASSWORD / B2_* from scripts/.env, then:
restic restore latest --tag infisical --target /tmp/restore
# import the dump into the container, then:

docker compose -f services/infisical/docker-compose.yml up -d
```

### 3. Start Traefik

```bash
docker compose -f services/traefik/docker-compose.yml up -d
```

### 4. Bootstrap Komodo manually

Komodo's own secrets live in Infisical, but it can't run its own pre-deploy hook. Run it manually once:

```bash
./scripts/fetch-secrets-pre-deploy.sh komodo
docker compose -f services/komodo/docker-compose.yaml up -d
./scripts/cleanup-secrets-post-deploy.sh komodo
```

### 5. Let Komodo deploy everything else

Once Komodo is up it will pull this repo and deploy all remaining services automatically using the pre/post deploy hooks to inject secrets from Infisical.
