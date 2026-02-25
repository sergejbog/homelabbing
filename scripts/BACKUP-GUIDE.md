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
```

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

## Scheduling Backups (Cron)

```bash
# Critical services - every 6 hours
0 */6 * * * cd /root/self-hosted && ./backup-manager.sh backup-all critical >> /var/log/backup-critical.log 2>&1

# High priority - every 12 hours
0 */12 * * * cd /root/self-hosted && ./backup-manager.sh backup-all high >> /var/log/backup-high.log 2>&1

# Medium priority - daily at 2 AM
0 2 * * * cd /root/self-hosted && ./backup-manager.sh backup-all medium >> /var/log/backup-medium.log 2>&1

# Low priority - weekly on Sunday at 3 AM
0 3 * * 0 cd /root/self-hosted && ./backup-manager.sh backup-all low >> /var/log/backup-low.log 2>&1
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
