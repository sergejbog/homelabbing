# Self-Hosted Homelab

A production-grade homelab running 31 self-hosted services across two servers, managed via GitOps with automated secrets injection, TLS termination, scheduled backups, and Ansible-based provisioning.

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

   ┌───────────┐     ┌─────────────┐     ┌──────────┐
   │ Infisical │     │   Komodo    │     │ Authentik│
   │ (secrets) │     │(orchestrate)│     │  (SSO)   │
   └───────────┘     └─────────────┘     └──────────┘
```

**Servers:**
- **host01** (primary): Komodo Core, Infisical, Traefik, Authentik, and most services
- **ex44** (secondary): Komodo Periphery, GitHub Runners, Grocy, Loki

**Key design decisions:**
- Each service lives in its own `services/<name>/` directory with a `docker-compose` file
- Secrets are **never stored in this repo** — injected at deploy time via [Infisical](https://infisical.com/) and cleaned up immediately after
- [Komodo](https://komo.do/) orchestrates deployments and syncs state from `main.toml` in this repo
- [Traefik](https://traefik.io/) handles routing and automatic TLS certificates via Let's Encrypt
- Encrypted offsite backups to Backblaze B2 via [Restic](https://restic.net/), scheduled via Komodo
- [Ansible](https://www.ansible.com/) provisions servers from scratch (packages, Docker, Infisical CLI, repo clone, encrypted `.env` files)

## Services

| Service | URL | Purpose |
|---|---|---|
| **traefik** | `traefik.domain` | Reverse proxy + TLS |
| **authentik** | `auth.domain` | SSO / Identity provider |
| **infisical** | `secrets.domain` | Secrets manager |
| **vaultwarden** | `vw.domain` | Password manager (Bitwarden-compatible) |
| **komodo** | `komodo.domain` | Deployment orchestrator |
| **n8n** | `automation.domain` | Workflow automation |
| **changedetection** | `change.domain` | Website change monitoring |
| **bookstack** | `wiki.domain` | Documentation wiki |
| **grafana** | `grafana.domain` | Metrics & dashboards (+ Tempo, Mimir, OTel) |
| **loki** | *(internal)* | Log aggregation |
| **uptime-kuma** | `uptime-kuma.domain` | Uptime monitoring |
| **node-exporter** | *(internal)* | System metrics |
| **notifications** | `notifications.domain` / `apprise.domain` | ntfy + Apprise |
| **chatwoot** | `chatwoot.domain` | Customer support |
| **freshrss** | `rss.domain` | RSS reader |
| **budibase** | `budibase.domain` | Low-code app builder |
| **bookstack** | `wiki.domain` | Documentation wiki |
| **firefly** | `finance.domain` | Personal finance |
| **wallos** | `wallos.domain` | Subscription tracker |
| **grocy** | `grocy.domain` | Household inventory |
| **glance** | `glance.domain` | Homepage dashboard |
| **it-tools** | `tools.domain` | IT utilities |
| **stirling-pdf** | `pdf.domain` | PDF toolkit |
| **reactive-resume** | `resume.domain` | Resume builder |
| **flaresolverr** | `flaresolverr.domain` | CloudFlare bypass proxy |
| **ipfs** | `ipfsGateway.domain` | IPFS node |
| **karakeep** | `karakeep.domain` | Karaoke manager |
| **epicgames-claimer** | `epicgamesclaimer.domain` | Epic Games free game claimer |
| **backrest** | `backrest.domain` | Backup UI (Restic) |
| **unleash** | `unleash.domain` | Feature flags |
| **github-runners** | *(internal)* | Self-hosted GitHub Actions (4 replicas, ex44) |

## Secrets Management

All secrets are stored in Infisical. Each service has a folder in Infisical matching its directory name under `services/`. Secrets are fetched immediately before deployment and deleted immediately after — they never persist on disk beyond the deploy lifecycle.

```
deploy → fetch-secrets-pre-deploy.sh → docker compose up → cleanup-secrets-post-deploy.sh
```

One secret is required at the **project root** in Infisical:

| Variable | Notes |
|---|---|
| `DOMAIN_NAME` | Used by virtually every service |

All other secrets are service-specific. Refer to each service's `.env.example` for what's needed.

The `scripts/.env` file (deployed by Ansible from vault) contains the Infisical client credentials and Restic/B2 backup credentials used by the pre-deploy hooks and backup scripts.

See `scripts/SETUP_INFISICAL.md` for initial Infisical CLI setup and `scripts/infisical-import-envs.sh` for bulk-importing existing `.env` files.

## Backup Strategy

Backups are orchestrated by Komodo's scheduling system — no manual cron required.

| Schedule | What |
|---|---|
| Daily 01:00 | Komodo Core database backup |
| Daily 01:10 | All services, staged by priority |
| Daily 03:00 | Pull repo, redeploy changed stacks |

**Backup destinations:** Backblaze B2 (encrypted with Restic)

**Notifications:** Backup results sent via Apprise

**Retention by priority:**

| Priority | Services | Daily | Weekly | Monthly |
|---|---|---|---|---|
| critical | infisical, vaultwarden, komodo | 14 | 8 | 24 |
| high | n8n, bookstack, chatwoot | 10 | 6 | 12 |
| medium | budibase, notifications, uptime-kuma, grocy, wallos | 7 | 4 | 6 |

The backup manager routes each service to the correct server via Komodo Periphery and supports PostgreSQL, MariaDB, Docker volumes, and directory backups.

```bash
# Manual backup commands (run on server)
./scripts/backup-manager.sh backup-all
./scripts/backup-manager.sh backup infisical
./scripts/backup-manager.sh restore infisical
./scripts/backup-manager.sh snapshots n8n
```

See `scripts/BACKUP-GUIDE.md` for full setup and restore instructions. Service backup configuration is in `scripts/backup-config.yml`.

## Provisioning (Ansible)

Ansible bootstraps servers from scratch: installs packages (Docker, Restic, Infisical CLI), clones this repo, and deploys encrypted `.env` files from Ansible Vault.

```bash
# Bootstrap a server
ansible-playbook ansible/playbooks/setup.yml --limit host01 --ask-vault-pass

# Teardown a server
ansible-playbook ansible/playbooks/teardown.yml --limit host01 --ask-vault-pass

# Test against a local Docker container first
cd ansible/test && docker compose up -d --build
cd .. && ansible-playbook playbooks/setup.yml --limit test --ask-vault-pass
```

Vault-encrypted secrets are in `ansible/host_vars/<host>/secrets.yml` and `ansible/group_vars/all/vault.yml`. Edit them with:

```bash
ansible-vault edit ansible/host_vars/host01/secrets.yml
```

See `ansible/scripts-to-run.md` for a full command reference.

## Bootstrap / Disaster Recovery

The bring-up order matters: Infisical must be running before any other service can fetch its secrets, and Komodo must be bootstrapped manually since it can't run its own pre-deploy hook.

### 1. Provision the server with Ansible

```bash
ansible-playbook ansible/playbooks/setup.yml --limit host01 --ask-vault-pass
```

This installs all dependencies, clones the repo to `/etc/komodo/repos/homelabbing`, and deploys the bootstrap `.env` files.

### 2. Start Infisical

```bash
# If recovering from backup: restore the database first
restic restore latest --tag infisical --target /tmp/restore
# import the dump into the postgres container, then:

docker compose -f services/infisical/docker-compose.yml up -d
```

### 3. Start Traefik

```bash
docker compose -f services/traefik/docker-compose.yml up -d
```

### 4. Bootstrap Komodo manually

Komodo can't run its own pre-deploy hook before it exists:

```bash
./scripts/fetch-secrets-pre-deploy.sh komodo
docker compose -f services/komodo/docker-compose.yaml up -d
./scripts/cleanup-secrets-post-deploy.sh komodo
```

### 5. Let Komodo deploy everything else

Once Komodo is up, it will pull this repo and deploy all remaining stacks automatically using the pre/post deploy hooks to inject secrets from Infisical.

For secondary servers (ex44), Ansible starts Komodo Periphery automatically during provisioning.

## Repository Structure

```
├── main.toml                    # Komodo GitOps config (stacks, procedures, actions)
├── services/                    # One directory per service
│   └── <service>/
│       ├── docker-compose.yml
│       ├── .env.example
│       └── .env                 # git-ignored, created at deploy time
├── scripts/
│   ├── backup-manager.sh        # Backup/restore orchestrator
│   ├── backup-config.yml        # Service backup configuration
│   ├── fetch-secrets-pre-deploy.sh
│   ├── cleanup-secrets-post-deploy.sh
│   ├── infisical-import-envs.sh # Bulk-import .env files into Infisical
│   ├── .env                     # git-ignored (Infisical + Restic credentials)
│   ├── .env.example
│   ├── BACKUP-GUIDE.md
│   └── SETUP_INFISICAL.md
└── ansible/
    ├── playbooks/
    │   ├── setup.yml
    │   ├── teardown.yml
    │   └── tasks/
    ├── group_vars/all/          # Shared variables + vault
    ├── host_vars/<host>/        # Per-host encrypted secrets
    ├── inventory.yml            # git-ignored
    ├── inventory.yml.example
    └── ansible.cfg
```
