# Backup Guide for Self-Hosted Services

## Quick Start

```bash
cd /etc/komodo/repos/homelabbing/scripts

./backup-manager.sh list                        # list all services
./backup-manager.sh list critical               # list by priority
./backup-manager.sh info <service>              # show service details
./backup-manager.sh backup <service>            # backup one service
./backup-manager.sh backup-all                  # backup all services
./backup-manager.sh backup-all critical         # backup by priority
./backup-manager.sh snapshots <service>         # list snapshots
./backup-manager.sh restore <service>           # interactive restore
./backup-manager.sh restore <service> latest    # restore latest
./backup-manager.sh restore <service> <id>      # restore specific snapshot
./backup-manager.sh add <service>               # add new service interactively
./backup-manager.sh sync-offsite                # copy new snapshots to offsite repo
./backup-manager.sh maintenance                 # retention + prune + check (weekly)
```

---

## Repository Architecture (3-2-1)

```
live data (both servers)
        │  restic backup  (daily, Komodo "Backup-All" @ 01:10)
        ▼
PRIMARY: rest-server on ex44          RESTIC_REPOSITORY
        │  restic copy    (daily, "Offsite Sync" stage after backups)
        ▼
OFFSITE: Backblaze B2                 RESTIC_REPOSITORY_OFFSITE
```

Why this layout:

- **Backups, restores, prune and check run against the primary** (rest-server
  on ex44) — fast, LAN-priced, no B2 transaction caps involved.
- **B2 only receives `restic copy` uploads** (Class A = free) plus light
  metadata reads. Class B (download) usage drops to almost nothing.
- **Restores never depend on B2 caps** unless both servers are gone — and for
  that true disaster case, raise the B2 daily caps (Account → Caps & Alerts)
  so a full restore can't be blocked mid-recovery.

### One-time setup of the primary repository

0. ex44 needs an HTTPS edge on its own host (labels are only seen by the
   Traefik running there). On ex44 that edge is Coolify's built-in Traefik
   proxy — apply the one-time customization in
   `services/traefik-edge/README.md` (Path 2), and create a Route53 A record
   `restic.<domain>` → ex44's IP.
1. Deploy the `restic-server` stack (server ex44), then create the HTTP user:
   ```bash
   docker exec -it restic-server create_user backups '<strong-password>'
   ```
2. Initialize the new primary with the SAME chunker parameters as the
   existing B2 repo (so future copies deduplicate against old data):
   ```bash
   restic -r "rest:https://backups:<pw>@restic.<domain>/" init \
       --from-repo "b2:<bucket>:/restic" \
       --from-password-file <(printf '%s' "$RESTIC_PASSWORD") \
       --copy-chunker-params
   ```
3. Update `scripts/.env` on BOTH servers:
   - `RESTIC_REPOSITORY` → the `rest:https://...` URL
   - `RESTIC_REPOSITORY_OFFSITE` → the old `b2:...` repo
4. (Optional) Seed old history into the primary — downloads the whole repo
   from B2 once, so raise the B2 caps first:
   ```bash
   restic copy --from-repo "b2:<bucket>:/restic" \
       --from-password-file <(printf '%s' "$RESTIC_PASSWORD")
   ```
5. Run the Komodo `Backup-All` procedure and confirm the final
   "Offsite Sync" stage copies the new snapshots to B2.

Until step 3 is done, everything keeps working against B2 directly, and
`sync-offsite` is a no-op.

### Dead man's switch (Uptime Kuma)

Create a **Push** monitor in Uptime Kuma (heartbeat interval ~86400s / 1 day,
retries 1) and put its bare push URL in `BACKUP_PUSH_URL` in `scripts/.env`.
Every successful service backup pings it; if no backup succeeds for a day,
Kuma alerts. Individual service failures are reported separately via Apprise.

---

## Backup Configuration

All services are configured in [backup-config.yml](backup-config.yml).

### Configuration Fields

| Field | Required | Description |
|-------|----------|-------------|
| `priority` | Yes | `critical`, `high`, `medium`, or `low` |
| `type` | Yes | `postgres`, `mariadb`, or `volume` |
| `container` | For DB types | Docker container name |
| `database` | For DB types | Database name |
| `user` | For DB types | Database user |
| `volumes` | For volume type | List of Docker volumes |
| `volumes_also` | No | Additional volumes to backup |
| `directories_also` | No | Directories to backup |
| `compose_file` | Yes | Path to docker-compose.yml |
| `requires_downtime` | No | Set to `true` for cold backups |
| `notes` | No | Documentation |

### Example Entry

```yaml
chatwoot:
  priority: high
  type: postgres
  container: chatwoot-postgres
  database: chatwoot
  user: postgres
  compose_file: services/chatwoot/docker-compose.yml
  volumes_also:
    - chatwoot_chatwoot-storage_data
  notes: "Customer support conversations"
```

---

## Scheduling

All scheduling runs through Komodo procedures (see `main.toml`):

| Procedure | Schedule | What it does |
|-----------|----------|--------------|
| `Backup-All` | Daily 01:10 | Per-service backups (critical → high → medium stages), then the "Offsite Sync" stage copies new snapshots to B2 |
| `Backup-Maintenance-Weekly` | Sunday 04:00 | Retention (`forget`) for every service, `prune` + `check` on the primary, retention + `prune` on the offsite repo |

Retention and prune are deliberately **not** part of the daily backup path:
`forget`/`prune` need restic's exclusive lock, which collides with the
parallel per-service backups, and prune is the expensive operation that
downloads and repacks data.

Cron fallback if Komodo scheduling is unavailable:

```bash
# Daily backups at 01:10
10 1 * * * /etc/komodo/repos/homelabbing/scripts/backup-manager.sh backup-all >> /var/log/backup-komodo.log 2>&1
15 3 * * * /etc/komodo/repos/homelabbing/scripts/backup-manager.sh sync-offsite >> /var/log/backup-komodo.log 2>&1

# Weekly maintenance on Sunday at 04:00
0 4 * * 0 /etc/komodo/repos/homelabbing/scripts/backup-manager.sh maintenance >> /var/log/backup-komodo.log 2>&1
```

---

## Restore Workflow

A restore is self-sufficient — `restore <service>` handles the whole flow,
including on a freshly provisioned host:

1. **.env** — if `services/<service>/.env` is missing (Komodo's post-deploy
   hook deletes it after every deploy), it is fetched from Infisical via
   `fetch-secrets-pre-deploy.sh`. An existing `.env` (e.g. placed by hand
   during disaster recovery) is left untouched.
2. **Containers + volumes** — `docker compose up -d` runs first, so the
   containers and named volumes exist before restic writes into them.
3. **DB readiness** — for postgres/mariadb restores the script waits until
   the database container accepts connections.
4. **Data restore** — the chosen snapshot, plus any `volumes_also` /
   `directories_also` snapshots from the same backup run.
5. **Komodo redeploy** — the stack is redeployed through the Komodo API
   (needs `KOMODO_URL`, `KOMODO_API_KEY`, `KOMODO_API_SECRET` in
   `scripts/.env`), so Komodo's stack state stays in sync and no manual
   "Redeploy" click is needed. If the API is unset or unreachable (e.g.
   Komodo itself is down), it falls back to `docker compose up -d`.

Typical run:

```bash
./backup-manager.sh backup <service>              # pre-restore safety snapshot
./backup-manager.sh snapshots <service>           # pick a snapshot
./backup-manager.sh restore <service> <snapshot>  # or 'latest'
```

Then verify with `docker compose logs -f` and by testing the application.

To only fetch a service's `.env` from Infisical (no restore), use the same
script the Komodo pre-deploy hook uses:

```bash
./fetch-secrets-pre-deploy.sh <service>
```

**Exception:** `komodo` (type `directory`) has no automatic restore — see
[Emergency Recovery](#emergency-recovery-bare-host) below.

---

## Service-Specific Restore Notes

**Infisical** — Restore FIRST on total loss. It holds passwords for every other service. Verify all secrets after restore.

**Vaultwarden** — Stop the service completely before restoring. Test with multiple vault clients after.

**n8n** — Restore both the database and the `n8n_storage` directory. Workflows and credentials live in separate locations.

**Budibase** — Requires cold backup (service down). Has three data stores: CouchDB, MinIO, and Redis — restore all three.

**Shared databases** (e.g. the `mariadb` container used by Bookstack) — Restore individual databases, not entire volumes, since multiple services may depend on the same container.

**Komodo** — Backed up as dated MongoDB dumps in `/etc/komodo/backups` (directory-type). No automatic restore: Komodo restores through its own CLI with the backup folder mounted — see Emergency Recovery below.

**Traefik** — Nothing to back up: config lives in git, `.env` lives in Infisical (fetch with `./fetch-secrets-pre-deploy.sh traefik`), and Let's Encrypt certificates re-issue automatically.

---

## Troubleshooting

**"RESTIC_REPOSITORY not set" / "scripts/.env not found"**

All restic/B2/Infisical/Komodo credentials live in `scripts/.env` (template:
`.env.example`). It is not in git or in any backup — restore it from
Bitwarden or the VeraCrypt volume.

**"Could not find password in .env"**

The script looks for the DB password in `services/<service>/.env` first and
falls back to the running container's environment. If both are missing,
fetch the .env from Infisical:
```bash
./fetch-secrets-pre-deploy.sh <service>
```

**Database restore permission error**
```bash
docker exec <container> psql -U postgres -c "DROP DATABASE <db>;"
docker exec <container> psql -U postgres -c "CREATE DATABASE <db> OWNER <user>;"
```

**Volume not found**
```bash
docker volume ls
docker compose -f services/<service>/docker-compose.yml config | grep volumes
```

**Check backup health**
```bash
restic check
restic stats
restic snapshots --latest 10
```

---

## Emergency Recovery (bare host)

Total-loss recovery follows a strict order because of the dependency chain:

```
Bitwarden / VeraCrypt (.env files) + Infisical CLI (SETUP_INFISICAL.md)
        → Infisical  (holds every other service's secrets)
        → Traefik    (ingress for the Infisical/Komodo UIs and the ex44
                      periphery alias; its .env is fetched FROM Infisical)
        → Komodo     (orchestration; restored via its own CLI)
        → everything else (backup-manager.sh restore, now automated)
```

### 0. Retrieve the bootstrap .env files (Bitwarden / VeraCrypt)

Three `.env` files are **not** in git and **not** in any backup repo. They
are stored in Bitwarden and on the VeraCrypt volume, and everything below
depends on them:

| File | Why it can't be fetched |
|------|------------------------|
| `scripts/.env` | Restic repo + password, B2 keys, Infisical machine identity, Komodo API keys, ntfy — needed before anything can be restored |
| `services/infisical/.env` | Infisical's own DB password and encryption keys — chicken-and-egg, can't come from Infisical |
| `services/komodo/.env` | Komodo DB credentials — needed before Komodo exists |

### 1. Bootstrap the host

```bash
apt install restic docker.io docker-compose-plugin git

# Clone to the path Komodo Periphery and the scripts expect
git clone https://github.com/sergejbog/homelabbing /etc/komodo/repos/homelabbing
cd /etc/komodo/repos/homelabbing

# Place the three .env files from step 0:
#   scripts/.env, services/infisical/.env, services/komodo/.env

# Shared Traefik network the compose files reference
docker network create proxy
```

Install the Infisical CLI now, following [SETUP_INFISICAL.md](SETUP_INFISICAL.md)
(install + copy to `/etc/komodo/bin/infisical`). It's needed from step 3
onward — `fetch-secrets-pre-deploy.sh` and every `backup-manager.sh restore`
use it to pull service `.env` files.

Sanity-check repo access:

```bash
cd scripts
set -a; . ./.env; set +a
restic snapshots --latest 5
```

### 2. Restore Infisical (secrets first)

```bash
./backup-manager.sh restore infisical latest
```

The script brings the stack up itself (creating containers and the
`pg_data` volume), waits for postgres, and imports the dump. The manually
placed `.env` is used as-is. Komodo isn't up yet, so the final redeploy
falls back to `docker compose up -d` — that's fine.

(The Infisical UI is behind traefik, so you can only verify the secrets
after step 3.)

### 3. Start Traefik

Traefik's `.env` does **not** come from Bitwarden — its values
(`DOMAIN_NAME`, `LETSENCRYPT_EMAIL`, `BASIC_AUTH`, `WIREGUARD_PEER_IP`,
`EX44_IP`) live in Infisical like every other service's, so fetch them with
the same script the Komodo pre-deploy hooks use:

```bash
./fetch-secrets-pre-deploy.sh traefik
(cd ../services/traefik && docker compose up -d)
```

This works even though `INFISICAL_API_URL` points at
`https://secrets.<domain>/api` (which routes through the not-yet-running
traefik): when that URL is unreachable, `fetch-secrets-pre-deploy.sh`
automatically falls back to talking to the `infisical-backend` container
directly over the docker bridge.

Note: the fetch script exports the root (`/`) folder and then `/traefik` —
if Infisical has no `/traefik` folder the second export fails, so keep that
folder present (even if empty; the shared root secrets cover most values).

Also make sure the DNS A records (Route53) point at the new host's IP,
or Let's Encrypt issuance and UI access will fail. Then verify: log into
Infisical at `https://secrets.<domain>` and confirm the secrets are there.

### 4. Restore Komodo (manual — deliberately not in backup-manager)

Komodo restores through its own CLI with the backup folder mounted into the
container ([docs](https://komo.do/docs/setup/backup#restore)). Because of
that mount requirement there is no automatic restore path in
`backup-manager.sh`.

1. Get the dated MongoDB dumps back on disk. The `komodo` entry backs up
   `/etc/komodo/backups` as a directory snapshot of its absolute path, so
   restoring against `/` puts it straight back:
   ```bash
   restic restore latest --tag komodo --target /
   ls /etc/komodo/backups
   ```

2. Start the Komodo stack with an empty database:
   ```bash
   (cd ../services/komodo && docker compose up -d)
   ```

3. Run the restore CLI against the mongo container (credentials from
   `services/komodo/.env`; restores the most recent backup, add
   `--restore-folder` for a specific one):
   ```bash
   docker run --rm --network proxy \
     -v /etc/komodo/backups:/backups \
     -e KOMODO_CLI_DATABASE_TARGET_ADDRESS="komodo-mongo-1:27017" \
     -e KOMODO_CLI_DATABASE_TARGET_USERNAME="<KOMODO_DB_USERNAME>" \
     -e KOMODO_CLI_DATABASE_TARGET_PASSWORD="<KOMODO_DB_PASSWORD>" \
     -e KOMODO_CLI_DATABASE_TARGET_DB_NAME="komodo" \
     ghcr.io/moghtech/komodo-cli km database restore -y
   ```
   Notes: check the mongo container name with `docker ps` (compose project
   `komodo`, service `mongo` → `komodo-mongo-1`). The restore does **not**
   clear the target database first — on a non-empty target, drop the db
   before restoring.

4. Restart core and verify:
   ```bash
   (cd ../services/komodo && docker compose restart core)
   ```
   Log into Komodo and confirm servers/stacks/procedures are back.

### 5. Restore the remaining services by priority

```bash
./backup-manager.sh restore vaultwarden latest   # critical
./backup-manager.sh restore n8n latest           # high
./backup-manager.sh restore bookstack latest
./backup-manager.sh restore chatwoot latest
./backup-manager.sh restore <service> latest     # medium: see 'list medium'
```

Each restore now fetches its `.env` from Infisical, creates containers and
volumes, restores the data, and finishes with a Komodo redeploy — no manual
steps between services.

**If both servers are gone** (primary rest-server repo lost too), point
`RESTIC_REPOSITORY` in `scripts/.env` at the offsite B2 repo
(`RESTIC_REPOSITORY_OFFSITE` value) and raise the B2 daily download caps
(Account → Caps & Alerts) before starting, so a full restore can't be
blocked mid-recovery.
