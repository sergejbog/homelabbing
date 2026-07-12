# Backup Guide for Self-Hosted Services

## Quick Start

```bash
cd ~/self-hosted

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
authentik:
  priority: high
  type: postgres
  container: postgresql
  database: authentik
  user: authentik
  compose_file: services/authentik/docker-compose.yml
  volumes_also:
    - media
    - postgresql
  directories_also:
    - services/authentik/media
  notes: "SSO authentication for all services"
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

1. Take a pre-restore snapshot:
   ```bash
   ./backup-manager.sh backup <service>
   ```

2. List available snapshots:
   ```bash
   ./backup-manager.sh snapshots <service>
   ```

3. Run the restore (script handles stop/start automatically):
   ```bash
   ./backup-manager.sh restore <service> <snapshot-id>
   ```

4. Verify: check `docker compose logs -f` and test the application.

### Manual Restore Scripts

For more control, use the scripts in [restore-scripts/](restore-scripts/):

```bash
./restore-scripts/postgres-restore.sh  <service> <snapshot-id> <container> <db> <user>
./restore-scripts/mariadb-restore.sh   <service> <snapshot-id> <container> <db> <user>
./restore-scripts/volume-restore.sh    <service> <snapshot-id> <volume>   <compose-dir>
```

---

## Service-Specific Restore Notes

**Infisical** — Restore FIRST on total loss. It holds passwords for every other service. Verify all secrets after restore.

**Vaultwarden** — Stop the service completely before restoring. Test with multiple vault clients after.

**n8n** — Restore both the database and the `n8n_storage` directory. Workflows and credentials live in separate locations.

**Budibase** — Requires cold backup (service down). Has three data stores: CouchDB, MinIO, and Redis — restore all three.

**Shared databases** (`databases-postgres`, `databases-mariadb`) — Restore individual databases, not entire volumes, since multiple services depend on these containers.

---

## Troubleshooting

**"RESTIC_REPOSITORY not set"**
```bash
grep RESTIC ~/.bashrc
# If missing:
echo 'export RESTIC_REPOSITORY="b2:your-bucket"' >> ~/.bashrc
echo 'export RESTIC_PASSWORD="your-password"' >> ~/.bashrc
source ~/.bashrc
```

**"Could not find password in .env"**
```bash
ls -la ~/self-hosted/services/<service>/.env
echo "DB_PASS=your-password" >> ~/self-hosted/services/<service>/.env
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

## Emergency Recovery (no Backrest UI)

```bash
apt install restic

export RESTIC_REPOSITORY="b2:your-bucket"
export RESTIC_PASSWORD="your-password"
export B2_ACCOUNT_ID="your-id"
export B2_ACCOUNT_KEY="your-key"

restic snapshots
restic restore <snapshot-id> --target /tmp/restore
# Then follow manual restore procedures above
```

### Disaster Recovery Order

```bash
./backup-manager.sh restore infisical latest   # secrets first
./backup-manager.sh restore authentik latest   # then SSO
./backup-manager.sh restore <service> latest   # then remaining by priority
```
