#!/bin/bash
#
# Backup Manager - Unified backup solution for self-hosted services
# Reads from backup-config.yml and manages backups/restores
#
# Usage:
#   ./backup-manager.sh list                           - List all configured services
#   ./backup-manager.sh backup <service>               - Backup a specific service
#   ./backup-manager.sh backup-all [priority]          - Backup all services (optionally filter by priority)
#   ./backup-manager.sh restore <service> [snapshot]   - Restore a service (interactive if no snapshot)
#   ./backup-manager.sh add <service>                  - Add a new service to config
#   ./backup-manager.sh info <service>                 - Show service backup info
#   ./backup-manager.sh snapshots <service>            - List snapshots for a service
#

set -euo pipefail

# Ensure standard binary paths are available (needed when invoked from Komodo terminal)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup-config.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Load Apprise environment
if [ -f "${SCRIPT_DIR}/.env" ]; then
    . "${SCRIPT_DIR}/.env"
    # Export variables for Infisical CLI
    export APPRISE_URL
    export APPRISE_CONFIG
    export APPRISE_LOGIN
    export NTFY_URL
    export NTFY_LOGIN

    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD
    export B2_ACCOUNT_ID
    export B2_ACCOUNT_KEY

    # Persistent cache so restic doesn't re-download repo metadata on every
    # invocation (Komodo terminals don't share a stable $HOME)
    export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
    mkdir -p "$RESTIC_CACHE_DIR"

    # Optional: offsite replica repositories (see 'sync-offsite') and
    # Uptime Kuma push monitor URL (dead man's switch)
    export RESTIC_REPOSITORY_OFFSITE="${RESTIC_REPOSITORY_OFFSITE:-}"
    export RESTIC_PASSWORD_OFFSITE="${RESTIC_PASSWORD_OFFSITE:-$RESTIC_PASSWORD}"
    export RESTIC_REPOSITORY_OFFSITE2="${RESTIC_REPOSITORY_OFFSITE2:-}"
    export RESTIC_PASSWORD_OFFSITE2="${RESTIC_PASSWORD_OFFSITE2:-$RESTIC_PASSWORD}"
    export BACKUP_PUSH_URL="${BACKUP_PUSH_URL:-}"

    # Optional: Komodo API credentials (Settings → Api Keys). When set,
    # restores finish with a proper Komodo stack redeploy instead of a bare
    # 'docker compose up -d' that leaves Komodo's stack state stale.
    export KOMODO_URL="${KOMODO_URL:-}"
    export KOMODO_API_KEY="${KOMODO_API_KEY:-}"
    export KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
else
    echo "❌ Error: ${SCRIPT_DIR}/.env not found"
    echo "Please create it with APPRISE_URL, APPRISE_CONFIG, and APPRISE_LOGIN"
    exit 1
fi

# Send Apprise notification
send_apprise_notification() {
    local title="$1"
    local body="$2"
    local type="${3:-info}"  # info, success, warning, failure

    if [ -z "${NTFY_URL:-}" ]; then
        echo -e "${YELLOW}Warning: NTFY_URL not set, skipping notification${NC}"
        return 0
    fi

    local logs_link="${GRAFANA_LOGS_URL:-https://grafana.yourdomain.com}"
    body+="\n\n[View Backup Logs]($logs_link)"

    # Send notification using apprise CLI or curl
    curl -X POST "$NTFY_URL/homelab-backup" \
            -u "$NTFY_LOGIN" \
            -H "Title: $title" \
            -H "Tags: white_check_mark,floppy_disk" \
            -h "Markdown: yes" \
            -d "$body" \
            --silent --show-error || echo -e "${YELLOW}Warning: Failed to send notification${NC}"
}

# Parse YAML (basic parser for our config structure)
parse_yaml() {
    local service=$1
    local field=$2

    # Extract service block and get field
    awk -v service="$service" -v field="$field" '
        /^  [a-z]/ { current_service=$1; gsub(/:/, "", current_service) }
        current_service == service && $1 == field":" {
            gsub(/^[^:]*: */, "");
            gsub(/^"/, "");
            gsub(/"$/, "");
            print;
        }
    ' "$CONFIG_FILE"
}

# Get YAML list values
parse_yaml_list() {
    local service=$1
    local field=$2

    awk -v service="$service" -v field="$field" '
        /^  [a-z]/ { current_service=$1; gsub(/:/, "", current_service); in_list=0 }
        current_service == service && $1 == field":" { in_list=1; next }
        in_list && /^      - / { gsub(/^      - /, ""); print }
        in_list && /^    [a-z]/ { in_list=0 }
    ' "$CONFIG_FILE"
}

# List all services
cmd_list() {
    echo -e "${CYAN}=== Configured Services ===${NC}\n"

    local priority_filter=${1:-}

    awk -v filter="$priority_filter" '
        /^  [a-z]/ {
            service=$1; gsub(/:/, "", service)
        }
        /^    priority:/ {
            priority=$2
            if (filter == "" || filter == priority) {
                services[service] = priority
            }
        }
        /^    type:/ { types[service] = $2 }
        END {
            printf "%-20s %-12s %-15s\n", "SERVICE", "PRIORITY", "TYPE"
            printf "%-20s %-12s %-15s\n", "-------", "--------", "----"
            for (s in services) {
                printf "%-20s %-12s %-15s\n", s, services[s], types[s]
            }
        }
    ' "$CONFIG_FILE"
}

# Show service info
cmd_info() {
    local service=$1

    if ! grep -q "^  $service:" "$CONFIG_FILE"; then
        echo -e "${RED}Error: Service '$service' not found in config${NC}"
        exit 1
    fi

    echo -e "${CYAN}=== Service: $service ===${NC}\n"

    local priority=$(parse_yaml "$service" "priority")
    local type=$(parse_yaml "$service" "type")
    local container=$(parse_yaml "$service" "container")
    local database=$(parse_yaml "$service" "database")
    local user=$(parse_yaml "$service" "user")
    local compose=$(parse_yaml "$service" "compose_file")
    local notes=$(parse_yaml "$service" "notes")

    echo -e "${YELLOW}Priority:${NC} $priority"
    echo -e "${YELLOW}Type:${NC} $type"

    if [ "$type" = "postgres" ] || [ "$type" = "mariadb" ]; then
        echo -e "${YELLOW}Container:${NC} $container"
        echo -e "${YELLOW}Database:${NC} $database"
        echo -e "${YELLOW}User:${NC} $user"
    fi

    # Show volumes
    local volumes=$(parse_yaml_list "$service" "volumes")
    if [ -n "$volumes" ]; then
        echo -e "${YELLOW}Volumes:${NC}"
        echo "$volumes" | while read vol; do
            echo "  - $vol"
        done
    fi

    local volumes_also=$(parse_yaml_list "$service" "volumes_also")
    if [ -n "$volumes_also" ]; then
        echo -e "${YELLOW}Additional Volumes:${NC}"
        echo "$volumes_also" | while read vol; do
            echo "  - $vol"
        done
    fi

    # Show directories
    local dirs=$(parse_yaml_list "$service" "directories_also")
    if [ -n "$dirs" ]; then
        echo -e "${YELLOW}Directories:${NC}"
        echo "$dirs" | while read dir; do
            echo "  - $dir"
        done
    fi

    echo -e "${YELLOW}Compose File:${NC} $compose"
    [ -n "$notes" ] && echo -e "${YELLOW}Notes:${NC} $notes"
}

# Backup a service. Runs the actual work (run_backup) in a child process so
# 'set -e' applies fully — a function called inside 'if' has errexit disabled,
# which previously let a failed restic step report success. Notifies on
# failure and pings the push monitor on success.
cmd_backup() {
    local service=$1
    local rc=0

    bash "$0" backup-inner "$service" || rc=$?

    if [ $rc -eq 0 ]; then
        if [ -n "$BACKUP_PUSH_URL" ]; then
            curl -fsS -m 10 --retry 2 "${BACKUP_PUSH_URL}?status=up&msg=${service}" > /dev/null || \
                echo -e "${YELLOW}Warning: Failed to ping push monitor${NC}"
        fi
    else
        send_apprise_notification "❌ Backup failed: $service" \
            "Backup of '$service' failed on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S').\nCheck the Komodo procedure logs for details." \
            "failure"
    fi

    return $rc
}

run_backup() {
    local service=$1

    if ! grep -q "^  $service:" "$CONFIG_FILE"; then
        echo -e "${RED}Error: Service '$service' not found in config${NC}"
        exit 1
    fi

    local type=$(parse_yaml "$service" "type")
    local priority=$(parse_yaml "$service" "priority")

    echo -e "${GREEN}Starting backup for: $service${NC}"
    echo -e "${CYAN}Type: $type | Priority: $priority${NC}\n"

    case "$type" in
        postgres)
            backup_postgres "$service"
            ;;
        mariadb)
            backup_mariadb "$service"
            ;;
        volume)
            backup_volume "$service"
            ;;
        directory)
            backup_directory_type "$service"
            ;;
        *)
            echo -e "${RED}Error: Unknown backup type: $type${NC}"
            exit 1
            ;;
    esac

    # Backup additional volumes if specified
    local volumes_also=$(parse_yaml_list "$service" "volumes_also")
    if [ -n "$volumes_also" ]; then
        echo -e "\n${CYAN}Backing up additional volumes...${NC}"
        echo "$volumes_also" | while read vol; do
            backup_single_volume "$service" "$vol"
        done
    fi

    # Backup directories if specified
    local dirs=$(parse_yaml_list "$service" "directories_also")
    if [ -n "$dirs" ]; then
        echo -e "\n${CYAN}Backing up directories...${NC}"
        echo "$dirs" | while read dir; do
            backup_directory "$service" "$dir"
        done
    fi

    echo -e "\n${GREEN}✓ Backup completed for: $service${NC}"
}

# Backup PostgreSQL database
backup_postgres() {
    local service=$1
    local container=$(parse_yaml "$service" "container")
    local database=$(parse_yaml "$service" "database")
    local user=$(parse_yaml "$service" "user")

    # Get password from compose file's .env
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"
    local password=""

    if [ -f "$compose_dir/.env" ]; then
        # Try common password variable names. The trailing '|| true' is load-
        # bearing: under 'set -euo pipefail' a grep no-match (or head SIGPIPE)
        # returns non-zero and would silently abort the whole script.
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|POSTGRES_PASSWORD|${database^^}_PASSWORD|DATABASE_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"' || true)
    fi

    # Fall back to the running container's own environment. This is the
    # authoritative source and works after cleanup-secrets-post-deploy.sh has
    # removed the on-disk .env on the Komodo servers.
    if [ -z "$password" ]; then
        password=$(docker exec "$container" printenv POSTGRES_PASSWORD 2>/dev/null || true)
    fi

    if [ -z "$password" ]; then
        echo -e "${YELLOW}Warning: Could not find password, trying without password${NC}"
        password=""
    fi

    echo "Dumping PostgreSQL database: $database from $container"

    # Use pg_dump
    local dump_file="/tmp/${service}_${database}_$(date +%Y%m%d_%H%M%S).sql"

    if [ -n "$password" ]; then
        docker exec "$container" sh -c "PGPASSWORD='$password' pg_dump -U $user $database" > "$dump_file"
    else
        docker exec "$container" pg_dump -U "$user" "$database" > "$dump_file"
    fi

    # Compress and upload to Restic
    echo "Uploading to Restic..."
    gzip "$dump_file"

    restic backup "${dump_file}.gz" \
        --tag "$service" \
        --tag "database" \
        --tag "postgres" \
        --tag "$database" \
        --tag plan:postgres \
        --tag created-by:hetzner-cloud

    rm "${dump_file}.gz"
}

# Backup MariaDB database
backup_mariadb() {
    local service=$1
    local container=$(parse_yaml "$service" "container")
    local database=$(parse_yaml "$service" "database")
    local user=$(parse_yaml "$service" "user")

    # Get password from compose file's .env
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"
    local password=""

    if [ -f "$compose_dir/.env" ]; then
        # '|| true' keeps a grep no-match from aborting the script under set -e
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|MYSQL_PASSWORD|MARIADB_PASSWORD|${database^^}_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"' || true)
    fi

    # Fall back to the running container's own environment
    if [ -z "$password" ]; then
        password=$(docker exec "$container" printenv MYSQL_PASSWORD 2>/dev/null || docker exec "$container" printenv MARIADB_PASSWORD 2>/dev/null || true)
    fi

    echo "Dumping MariaDB database: $database from $container"

    # Check which dump command is available (mariadb-dump or mysqldump)
    local dump_cmd="mysqldump"
    if docker exec "$container" test -f /usr/bin/mariadb-dump 2>/dev/null; then
        dump_cmd="mariadb-dump"
    elif docker exec "$container" which mariadb-dump 2>/dev/null; then
        dump_cmd="mariadb-dump"
    fi

    echo "Using dump command: $dump_cmd"

    # Use mysqldump or mariadb-dump
    local dump_file="/tmp/${service}_${database}_$(date +%Y%m%d_%H%M%S).sql"

    docker exec "$container" "$dump_cmd" -u"$user" -p"$password" "$database" > "$dump_file"

    # Compress and upload to Restic
    echo "Uploading to Restic..."
    gzip "$dump_file"

    restic backup "${dump_file}.gz" \
        --tag "$service" \
        --tag "database" \
        --tag "mariadb" \
        --tag "$database" \
        --tag plan:mariadb \
        --tag created-by:hetzner-cloud

    rm "${dump_file}.gz"
}

# Backup volume(s)
backup_volume() {
    local service=$1
    local volumes=$(parse_yaml_list "$service" "volumes")

    if [ -z "$volumes" ]; then
        echo -e "${RED}Error: No volumes specified for $service${NC}"
        exit 1
    fi

    local requires_downtime=$(parse_yaml "$service" "requires_downtime")
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"

    # Stop service if required
    if [ "$requires_downtime" = "true" ]; then
        echo -e "${YELLOW}Stopping service for cold backup...${NC}"
        (cd "$compose_dir" && docker compose down)
    fi

    # Backup each volume
    echo "$volumes" | while read vol; do
        backup_single_volume "$service" "$vol"
    done

    # Restart service if we stopped it
    if [ "$requires_downtime" = "true" ]; then
        echo -e "${YELLOW}Starting service...${NC}"
        (cd "$compose_dir" && docker compose up -d)
    fi
}

# Backup a single volume
backup_single_volume() {
    local service=$1
    local volume=$2

    echo "Backing up volume: $volume"

    # Get volume mountpoint
    local mountpoint=$(docker volume inspect "$volume" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")

    if [ -z "$mountpoint" ]; then
        echo -e "${RED}Error: Volume $volume not found${NC}"
        return 1
    fi

    # Backup the volume
    restic backup "$mountpoint" \
        --tag "$service" \
        --tag "volume" \
        --tag "$volume" \
        --tag plan:volume \
        --tag created-by:hetzner-cloud
}

# Backup directory type (main backup target)
backup_directory_type() {
    local service=$1
    local directory=$(parse_yaml "$service" "directory")

    if [ -z "$directory" ]; then
        echo -e "${RED}Error: No directory specified for $service${NC}"
        exit 1
    fi

    if [ ! -d "$directory" ]; then
        echo -e "${RED}Error: Directory not found: $directory${NC}"
        exit 1
    fi

    echo "Backing up directory: $directory"

    restic backup "$directory" \
        --tag "$service" \
        --tag "directory" \
        --tag "$(basename "$directory")" \
        --tag plan:directory \
        --tag created-by:hetzner-cloud
}

# Backup a directory
backup_directory() {
    local service=$1
    local dir=$2

    local full_path="$ROOT_DIR/$dir"

    if [ ! -d "$full_path" ]; then
        echo -e "${YELLOW}Warning: Directory not found: $full_path${NC}"
        return 1
    fi

    echo "Backing up directory: $dir"

    restic backup "$full_path" \
        --tag "$service" \
        --tag "directory" \
        --tag "$(basename "$dir")" \
        --tag plan:directory \
        --tag created-by:hetzner-cloud
}

# Apply retention policy (forget only — marks old snapshots for removal).
# Deliberately NOT --prune: forget is a cheap metadata operation, while prune
# is the expensive garbage collection that downloads and repacks data. Prune
# runs once a week via 'maintenance' instead of once per service per day.
apply_retention() {
    local service=$1
    local priority=$(parse_yaml "$service" "priority")

    # Get retention values from config
    local daily=$(awk -v p="$priority" '/^  [a-z]/ {current=$1; gsub(/:/, "", current)} current == p && /daily:/ {print $2}' "$CONFIG_FILE" | grep -E '^[0-9]+$' | head -1)
    local weekly=$(awk -v p="$priority" '/^  [a-z]/ {current=$1; gsub(/:/, "", current)} current == p && /weekly:/ {print $2}' "$CONFIG_FILE" | grep -E '^[0-9]+$' | head -1)
    local monthly=$(awk -v p="$priority" '/^  [a-z]/ {current=$1; gsub(/:/, "", current)} current == p && /monthly:/ {print $2}' "$CONFIG_FILE" | grep -E '^[0-9]+$' | head -1)

    # Use defaults if not found
    daily=${daily:-7}
    weekly=${weekly:-4}
    monthly=${monthly:-6}

    echo "Applying retention policy (daily:$daily weekly:$weekly monthly:$monthly)..."

    restic forget \
        --tag "$service" \
        --keep-daily "$daily" \
        --keep-weekly "$weekly" \
        --keep-monthly "$monthly"
}

# Copy new snapshots from the primary repository to the offsite replica.
# Reads from the primary (free when it's a local/rest-server repo) and only
# uploads to the offsite — B2 uploads are Class A transactions, which are free.
# sync_to_repo <repo> <password> <label>: copy the primary repository's
# snapshots into one offsite target, initializing it on first run
sync_to_repo() {
    local repo=$1 password=$2 label=$3

    echo -e "${GREEN}=== Syncing snapshots to ${label} repository ===${NC}"

    # First run: initialize the offsite repo with the same chunker parameters
    # as the primary, so copied data deduplicates properly
    if ! RESTIC_PASSWORD="$password" restic -r "$repo" cat config > /dev/null 2>&1; then
        echo "${label} repository not initialized, creating it..."
        RESTIC_PASSWORD="$password" restic -r "$repo" init \
            --from-repo "$RESTIC_REPOSITORY" \
            --from-password-file <(printf '%s' "$RESTIC_PASSWORD") \
            --copy-chunker-params
    fi

    if RESTIC_PASSWORD="$password" restic -r "$repo" copy \
        --from-repo "$RESTIC_REPOSITORY" \
        --from-password-file <(printf '%s' "$RESTIC_PASSWORD"); then
        echo -e "${GREEN}✓ ${label} sync completed${NC}"
    else
        send_apprise_notification "❌ Offsite sync failed" \
            "restic copy to the ${label} repository failed on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')." \
            "failure"
        return 1
    fi
}

# Sync to every configured offsite repo; a failure on one target doesn't
# skip the others, but the command still exits non-zero
cmd_sync_offsite() {
    if [ -z "$RESTIC_REPOSITORY_OFFSITE" ] && [ -z "$RESTIC_REPOSITORY_OFFSITE2" ]; then
        echo -e "${YELLOW}No offsite repository configured, skipping offsite sync${NC}"
        return 0
    fi

    local rc=0
    if [ -n "$RESTIC_REPOSITORY_OFFSITE" ]; then
        sync_to_repo "$RESTIC_REPOSITORY_OFFSITE" "$RESTIC_PASSWORD_OFFSITE" "offsite" || rc=1
    fi
    if [ -n "$RESTIC_REPOSITORY_OFFSITE2" ]; then
        sync_to_repo "$RESTIC_REPOSITORY_OFFSITE2" "$RESTIC_PASSWORD_OFFSITE2" "offsite-2" || rc=1
    fi
    return $rc
}

# Weekly maintenance wrapper: child process for correct errexit semantics
# (same pattern as cmd_backup), plus notifications either way.
cmd_maintenance() {
    local rc=0

    bash "$0" maintenance-inner || rc=$?

    if [ $rc -eq 0 ]; then
        send_apprise_notification "✅ Backup maintenance completed" \
            "Retention, prune and check completed on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')." \
            "success"
    else
        send_apprise_notification "❌ Backup maintenance failed" \
            "Maintenance run failed on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S').\nCheck the Komodo procedure logs for details." \
            "failure"
    fi

    return $rc
}

# Apply retention for every service (serialized — forget needs an exclusive
# lock, so this must not run while parallel backups hold shared locks), then
# prune and verify the primary, then do the same retention + prune offsite.
# The offsite 'check' is intentionally omitted: check re-downloads all repo
# metadata every run, which is expensive on B2 — run it monthly by hand or
# via Backrest instead.
run_maintenance() {
    local services=$(awk '
        /^  [a-z]/ { service=$1; gsub(/:/, "", service) }
        /^    priority:/ { print service }
    ' "$CONFIG_FILE")

    echo -e "${GREEN}=== Primary repository maintenance ===${NC}"

    # Remove stale locks left behind by crashed/killed runs (safe: only
    # removes locks whose owning process is gone)
    restic unlock

    for service in $services; do
        apply_retention "$service"
    done

    echo "Pruning primary repository..."
    restic prune

    echo "Checking primary repository..."
    restic check

    if [ -n "$RESTIC_REPOSITORY_OFFSITE" ]; then
        maintain_offsite_repo "$RESTIC_REPOSITORY_OFFSITE" "$RESTIC_PASSWORD_OFFSITE" "offsite" "$services"
    fi
    if [ -n "$RESTIC_REPOSITORY_OFFSITE2" ]; then
        maintain_offsite_repo "$RESTIC_REPOSITORY_OFFSITE2" "$RESTIC_PASSWORD_OFFSITE2" "offsite-2" "$services"
    fi

    echo -e "${GREEN}✓ Maintenance completed${NC}"
}

# maintain_offsite_repo <repo> <password> <label> <services>: retention +
# prune for one offsite replica (no 'check' — see run_maintenance comment)
maintain_offsite_repo() {
    local repo=$1 password=$2 label=$3 services=$4

    echo -e "\n${GREEN}=== ${label} repository maintenance ===${NC}"
    (
        export RESTIC_REPOSITORY="$repo"
        export RESTIC_PASSWORD="$password"

        restic unlock

        for service in $services; do
            apply_retention "$service"
        done

        echo "Pruning ${label} repository..."
        restic prune
    )
}

# Backup all services
cmd_backup_all() {
    local priority_filter=${1:-}

    echo -e "${GREEN}=== Backing up all services ===${NC}\n"

    local services=$(awk -v filter="$priority_filter" '
        /^  [a-z]/ { service=$1; gsub(/:/, "", service) }
        /^    priority:/ {
            if (filter == "" || filter == $2) {
                print service
            }
        }
    ' "$CONFIG_FILE")

    local count=0
    local failed=0
    local successful_services=()
    local failed_services=()

    # Disable exit on error for the loop so all services are attempted
    set +e

    for service in $services; do
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if cmd_backup "$service"; then
            ((count++))
            successful_services+=("$service")
        else
            echo -e "${RED}✗ Failed to backup: $service${NC}"
            ((failed++))
            failed_services+=("$service")
        fi
    done

    # Re-enable exit on error
    set -e

    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Completed: $count successful, $failed failed${NC}"

    # Send Apprise notification
    local notification_title="Backup Report"
    local notification_body=""
    local notification_type="success"

    if [ $failed -eq 0 ]; then
        notification_title="✅ Backup Completed Successfully"
        notification_body="All $count services backed up successfully."
        notification_type="success"
    else
        notification_title="⚠️ Backup Completed with Failures"
        notification_type="warning"
    fi

    # Build notification body
    notification_body+="\n\n📊 Summary:\n"
    notification_body+="✅ Successful: $count\n"
    notification_body+="❌ Failed: $failed\n"

    if [ ${#successful_services[@]} -gt 0 ]; then
        notification_body+="\n✅ Successful Services:\n"
        for service in "${successful_services[@]}"; do
            notification_body+="  • $service\n"
        done
    fi

    if [ ${#failed_services[@]} -gt 0 ]; then
        notification_body+="\n❌ Failed Services:\n"
        for service in "${failed_services[@]}"; do
            notification_body+="  • $service\n"
        done
    fi

    notification_body+="\n🕐 Completed: $(date '+%Y-%m-%d %H:%M:%S')"

    send_apprise_notification "$notification_title" "$notification_body" "$notification_type"
}

# List snapshots for a service
cmd_snapshots() {
    local service=$1

    echo -e "${CYAN}=== Snapshots for: $service ===${NC}\n"

    restic snapshots --tag "$service" --compact
}

# --- Restore orchestration helpers ------------------------------------------

# Make sure the service folder has a .env before compose runs. Komodo's
# post-deploy hook deletes .env after every deploy, so on restore it is
# normally missing — fetch it from Infisical exactly like the pre-deploy hook
# does. A .env that is already present (e.g. placed by hand during disaster
# recovery, before Infisical itself is back) is left untouched.
ensure_service_env() {
    local compose_dir=$1
    local service_dir=$(basename "$compose_dir")

    if [ -f "$compose_dir/.env" ]; then
        echo "Using existing .env in $compose_dir"
        return 0
    fi

    echo "Fetching .env from Infisical for: $service_dir"
    if ! bash "$SCRIPT_DIR/fetch-secrets-pre-deploy.sh" "$service_dir"; then
        echo -e "${YELLOW}Warning: could not fetch .env from Infisical — continuing without it${NC}"
    fi
}

# Bring the stack up before restoring so containers and named volumes exist
# (the fresh-host case, where restore used to fail until you ran compose up
# by hand). Tolerant on purpose: if the stack is already running or compose
# can't start it, the restore continues against whatever is running.
ensure_stack_up() {
    local compose_dir=$1

    echo "Ensuring containers and volumes exist (docker compose up -d)..."
    if ! (cd "$compose_dir" && docker compose up -d); then
        echo -e "${YELLOW}Warning: docker compose up failed — continuing with currently running containers${NC}"
    fi
}

# Wait for a freshly started database container to accept connections
wait_for_db() {
    local container=$1
    local type=$2

    echo "Waiting for $container to accept connections..."
    for _ in $(seq 1 30); do
        if [ "$type" = "postgres" ]; then
            docker exec "$container" pg_isready -q > /dev/null 2>&1 && return 0
        else
            docker exec "$container" sh -c 'mariadb-admin ping --silent || mysqladmin ping --silent' > /dev/null 2>&1 && return 0
        fi
        sleep 2
    done

    echo -e "${YELLOW}Warning: $container not ready after 60s — attempting restore anyway${NC}"
}

# Hand the service back to Komodo after a restore. A Komodo redeploy runs the
# stack's own pre-deploy secret fetch and keeps the stack state in sync — a
# bare 'docker compose up -d' would leave Komodo showing a stale deployment
# and require a manual "Redeploy" click. Falls back to compose when the
# Komodo API isn't configured or reachable (e.g. Komodo itself is down).
redeploy_stack() {
    local service=$1
    local compose_dir=$2
    local stack=$(parse_yaml "$service" "komodo_stack")
    stack=${stack:-$service}

    if [ -n "$KOMODO_URL" ] && [ -n "$KOMODO_API_KEY" ]; then
        echo "Triggering Komodo redeploy of stack: $stack"
        if curl -fsS -m 30 -X POST "${KOMODO_URL%/}/execute" \
            -H "X-Api-Key: $KOMODO_API_KEY" \
            -H "X-Api-Secret: $KOMODO_API_SECRET" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"DeployStack\",\"params\":{\"stack\":\"$stack\"}}" > /dev/null; then
            echo -e "${GREEN}✓ Komodo redeploy triggered for: $stack${NC}"
            return 0
        fi
        echo -e "${YELLOW}Warning: Komodo API redeploy failed — falling back to docker compose${NC}"
    else
        echo -e "${YELLOW}KOMODO_URL/KOMODO_API_KEY not set — starting via docker compose (remember to Redeploy in Komodo)${NC}"
    fi

    # --force-recreate mirrors what a Komodo redeploy does: running app
    # containers are restarted so none keep stale connections to the
    # pre-restore data.
    (cd "$compose_dir" && docker compose up -d --force-recreate)
}

# Restore service
cmd_restore() {
    local service=$1
    local snapshot_id=${2:-}

    if ! grep -q "^  $service:" "$CONFIG_FILE"; then
        echo -e "${RED}Error: Service '$service' not found in config${NC}"
        exit 1
    fi

    local type=$(parse_yaml "$service" "type")

    # Directory-type services (komodo) restore through their own tooling —
    # Komodo needs the backup folder mounted into the komodo-cli container.
    # See BACKUP-GUIDE.md "Emergency Recovery" for the exact steps.
    if [ "$type" = "directory" ]; then
        echo -e "${RED}'$service' is a directory-type backup and has no automatic restore.${NC}"
        echo "Follow the manual steps in scripts/BACKUP-GUIDE.md (Emergency Recovery)."
        exit 1
    fi

    # If no snapshot specified, show available snapshots and prompt
    if [ -z "$snapshot_id" ]; then
        echo -e "${CYAN}Available snapshots for $service (type: $type):${NC}\n"

        # Filter snapshots by type
        if [ "$type" = "postgres" ] || [ "$type" = "mariadb" ]; then
            # comma-separated tags = AND, so this is scoped to THIS service only
            restic snapshots --tag "$service,database"
        else
            restic snapshots --tag "$service,volume"
        fi
        echo ""
        read -p "Enter snapshot ID to restore (or 'latest'): " snapshot_id
    fi

    if [ "$snapshot_id" = "latest" ]; then
        # Get latest snapshot matching the backup type
        if [ "$type" = "postgres" ] || [ "$type" = "mariadb" ]; then
            snapshot_id=$(restic snapshots --tag "$service" --json | jq -r '[.[] | select(.tags | contains(["database"]))] | .[-1].short_id')
        else
            snapshot_id=$(restic snapshots --tag "$service" --json | jq -r '[.[] | select(.tags | contains(["volume"]))] | .[-1].short_id')
        fi
    fi

    echo -e "${YELLOW}⚠ Warning: This will restore $service from snapshot $snapshot_id${NC}"
    read -p "Continue? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Restore cancelled"
        exit 0
    fi

    # Make the restore self-sufficient: fetch the .env (compose interpolation
    # and DB passwords need it) and create containers + volumes before restic
    # writes anything, so a restore works on a freshly provisioned host too.
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"

    ensure_service_env "$compose_dir"
    ensure_stack_up "$compose_dir"

    case "$type" in
        postgres)
            wait_for_db "$(parse_yaml "$service" "container")" "$type"
            restore_postgres "$service" "$snapshot_id"
            ;;
        mariadb)
            wait_for_db "$(parse_yaml "$service" "container")" "$type"
            restore_mariadb "$service" "$snapshot_id"
            ;;
        volume)
            restore_volume "$service" "$snapshot_id"
            ;;
        *)
            echo -e "${RED}Error: Unknown backup type: $type${NC}"
            exit 1
            ;;
    esac

    # Resolve the timestamp of the primary snapshot the user chose, so any
    # additional volumes/directories are restored from the SAME backup run
    # rather than whatever happens to be newest across all services.
    local anchor_time=$(restic snapshots "$snapshot_id" --json 2>/dev/null | jq -r '.[0].time // empty')

    # Restore additional volumes if specified. Each volume is its own snapshot
    # tagged <service> + volume + <volume-name>, so we resolve one snapshot PER
    # volume, scoped to this service (comma tags = AND) and matched to the chosen
    # run. Previously this grabbed the newest 'volume' snapshot of ANY service
    # (--tag a --tag b is OR in restic), which restored the wrong service's data.
    local volumes_also=$(parse_yaml_list "$service" "volumes_also")
    if [ -n "$volumes_also" ]; then
        echo -e "\n${CYAN}Restoring additional volumes...${NC}"

        echo "$volumes_also" | while read vol; do
            [ -z "$vol" ] && continue
            echo -e "\n${CYAN}Restoring additional volume: $vol${NC}"

            # This volume's snapshot from the chosen run: the earliest snapshot
            # at or after the anchor time (volumes are backed up just after the
            # DB within a run); fall back to the newest if none match.
            local vol_snapshot=$(restic snapshots --tag "$service,volume,$vol" --json 2>/dev/null \
                | jq -r --arg t "$anchor_time" '
                    if $t == "" then .[-1].short_id
                    else (([.[] | select(.time >= $t)] | .[0].short_id) // .[-1].short_id)
                    end // empty')

            if [ -z "$vol_snapshot" ]; then
                echo -e "${YELLOW}Warning: No snapshot found for volume $vol, skipping${NC}"
                continue
            fi
            echo "Using snapshot: $vol_snapshot"

            local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
            if [ -z "$mountpoint" ]; then
                echo -e "${YELLOW}Warning: Volume $vol not found, skipping${NC}"
                continue
            fi
            echo "Volume mountpoint: $mountpoint"

            local restore_dir="/tmp/restore_${service}_${vol}_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$restore_dir"
            echo "Restoring volume snapshot..."
            restic restore "$vol_snapshot" --target "$restore_dir"

            # A volume snapshot contains exactly one volume's _data directory
            local volume_backup_path=$(find "$restore_dir" -type d -name "_data" | head -1)
            if [ -n "$volume_backup_path" ] && [ -d "$volume_backup_path" ]; then
                echo "Clearing existing data..."
                rm -rf "${mountpoint:?}"/*
                rm -rf "${mountpoint:?}"/.[!.]* 2>/dev/null || true
                echo "Copying data from: $volume_backup_path"
                cp -a "$volume_backup_path"/. "$mountpoint/" 2>/dev/null || true
                local copied_files=$(find "$mountpoint" -type f | wc -l)
                echo "Files copied: $copied_files"
            else
                echo -e "${YELLOW}Warning: Could not find volume data for $vol${NC}"
            fi
            rm -rf "$restore_dir"
        done
    fi

    # Restore additional directories if specified. Same model as volumes: one
    # snapshot per directory, scoped to this service and matched to the run.
    local dirs_also=$(parse_yaml_list "$service" "directories_also")
    if [ -n "$dirs_also" ]; then
        echo -e "\n${CYAN}Restoring additional directories...${NC}"

        echo "$dirs_also" | while read dir; do
            [ -z "$dir" ] && continue
            local dir_basename=$(basename "$dir")
            echo -e "\n${CYAN}Restoring additional directory: $dir${NC}"

            local dir_snapshot=$(restic snapshots --tag "$service,directory,$dir_basename" --json 2>/dev/null \
                | jq -r --arg t "$anchor_time" '
                    if $t == "" then .[-1].short_id
                    else (([.[] | select(.time >= $t)] | .[0].short_id) // .[-1].short_id)
                    end // empty')

            if [ -z "$dir_snapshot" ]; then
                echo -e "${YELLOW}Warning: No snapshot found for directory $dir, skipping${NC}"
                continue
            fi
            echo "Using snapshot: $dir_snapshot"

            local target_path="$ROOT_DIR/$dir"
            mkdir -p "$(dirname "$target_path")"

            local restore_dir="/tmp/restore_${service}_${dir_basename}_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$restore_dir"
            echo "Restoring directory snapshot..."
            restic restore "$dir_snapshot" --target "$restore_dir"

            local dir_backup_path=$(find "$restore_dir" -type d -path "*/$dir" | head -1)
            if [ -z "$dir_backup_path" ]; then
                dir_backup_path=$(find "$restore_dir" -type d -name "$dir_basename" | head -1)
            fi

            if [ -n "$dir_backup_path" ] && [ -d "$dir_backup_path" ]; then
                echo "Copying data from: $dir_backup_path"
                echo "To: $target_path"
                rm -rf "$target_path"
                cp -a "$dir_backup_path" "$target_path"
                local copied_files=$(find "$target_path" -type f 2>/dev/null | wc -l)
                echo "Files copied: $copied_files"
            else
                echo -e "${YELLOW}Warning: Could not find directory data for $dir${NC}"
                echo "Searched in: $restore_dir"
            fi
            rm -rf "$restore_dir"
        done
    fi

    # Bring the service back through Komodo (or compose fallback) so every
    # container starts fresh against the restored data and the Komodo stack
    # state stays in sync — no manual "Redeploy" needed anymore.
    echo ""
    redeploy_stack "$service" "$compose_dir"

    echo -e "\n${GREEN}✓ Restore completed for: $service${NC}"
}

# Restore PostgreSQL
restore_postgres() {
    local service=$1
    local snapshot_id=$2
    local container=$(parse_yaml "$service" "container")
    local database=$(parse_yaml "$service" "database")
    local user=$(parse_yaml "$service" "user")

    # Get password
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"
    local password=""

    if [ -f "$compose_dir/.env" ]; then
        # '|| true' is required: without it a grep no-match aborts the restore
        # silently under 'set -euo pipefail', before the echo below ever runs.
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|POSTGRES_PASSWORD|${database^^}_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"' || true)
    fi

    # Fall back to the running container's own environment
    if [ -z "$password" ]; then
        password=$(docker exec "$container" printenv POSTGRES_PASSWORD 2>/dev/null || true)
    fi

    echo "Restoring PostgreSQL database: $database"

    # Download snapshot
    local restore_dir="/tmp/restore_${service}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$restore_dir"

    restic restore "$snapshot_id" --target "$restore_dir" --tag "$service" --tag "database"

    # Find the dump file
    local dump_file=$(find "$restore_dir" -name "*.sql.gz" | head -1)

    if [ -z "$dump_file" ]; then
        echo -e "${RED}Error: Could not find dump file in snapshot${NC}"
        rm -rf "$restore_dir"
        exit 1
    fi

    # Decompress
    gunzip "$dump_file"
    dump_file="${dump_file%.gz}"

    # Verify SQL file exists and has content
    if [ ! -f "$dump_file" ]; then
        echo -e "${RED}Error: SQL dump file not found after decompression${NC}"
        rm -rf "$restore_dir"
        exit 1
    fi

    local file_size=$(stat -f%z "$dump_file" 2>/dev/null || stat -c%s "$dump_file" 2>/dev/null)
    echo "SQL dump file size: $file_size bytes"

    if [ "$file_size" -lt 100 ]; then
        echo -e "${RED}Error: SQL dump file is suspiciously small${NC}"
        rm -rf "$restore_dir"
        exit 1
    fi

    # Drop and recreate database
    echo "Recreating database..."
    if [ -n "$password" ]; then
        # Terminate all connections to the database
        echo "Terminating active connections..."
        docker exec "$container" sh -c "PGPASSWORD='$password' psql -U $user -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$database' AND pid <> pg_backend_pid();\""

        # Drop database
        echo "Dropping database..."
        docker exec "$container" sh -c "PGPASSWORD='$password' psql -U $user -d postgres -c 'DROP DATABASE IF EXISTS $database;'"

        # Create database
        echo "Creating database..."
        docker exec "$container" sh -c "PGPASSWORD='$password' psql -U $user -d postgres -c 'CREATE DATABASE $database;'"

        # Import SQL dump with error checking
        echo "Importing SQL dump..."
        if ! docker exec -i "$container" sh -c "PGPASSWORD='$password' psql -U $user -d $database --set ON_ERROR_STOP=on" < "$dump_file"; then
            echo -e "${RED}Error: Failed to import SQL dump${NC}"
            rm -rf "$restore_dir"
            exit 1
        fi

        # Verify import
        echo "Verifying import..."
        local table_count=$(docker exec "$container" sh -c "PGPASSWORD='$password' psql -U $user -d $database -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';\"" | tr -d ' ')
        echo "Tables imported: $table_count"

        if [ "$table_count" -eq 0 ]; then
            echo -e "${RED}Warning: No tables found in database after import!${NC}"
        fi
    else
        # Terminate all connections to the database
        echo "Terminating active connections..."
        docker exec "$container" psql -U "$user" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$database' AND pid <> pg_backend_pid();"

        # Drop database
        echo "Dropping database..."
        docker exec "$container" psql -U "$user" -d postgres -c "DROP DATABASE IF EXISTS $database;"

        # Create database
        echo "Creating database..."
        docker exec "$container" psql -U "$user" -d postgres -c "CREATE DATABASE $database;"

        # Import SQL dump with error checking
        echo "Importing SQL dump..."
        if ! docker exec -i "$container" psql -U "$user" -d "$database" --set ON_ERROR_STOP=on < "$dump_file"; then
            echo -e "${RED}Error: Failed to import SQL dump${NC}"
            rm -rf "$restore_dir"
            exit 1
        fi

        # Verify import
        echo "Verifying import..."
        local table_count=$(docker exec "$container" psql -U "$user" -d "$database" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" | tr -d ' ')
        echo "Tables imported: $table_count"

        if [ "$table_count" -eq 0 ]; then
            echo -e "${RED}Warning: No tables found in database after import!${NC}"
        fi
    fi

    # Cleanup
    rm -rf "$restore_dir"
}

# Restore MariaDB
restore_mariadb() {
    local service=$1
    local snapshot_id=$2
    local container=$(parse_yaml "$service" "container")
    local database=$(parse_yaml "$service" "database")
    local user=$(parse_yaml "$service" "user")

    # Get password
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"
    local password=""

    if [ -f "$compose_dir/.env" ]; then
        # '|| true' keeps a grep no-match from silently aborting under set -e
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|MYSQL_PASSWORD|MARIADB_PASSWORD|${database^^}_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"' || true)
    fi

    # Fall back to the running container's own environment
    if [ -z "$password" ]; then
        password=$(docker exec "$container" printenv MYSQL_PASSWORD 2>/dev/null || docker exec "$container" printenv MARIADB_PASSWORD 2>/dev/null || true)
    fi

    echo "Restoring MariaDB database: $database"

    # Download snapshot
    local restore_dir="/tmp/restore_${service}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$restore_dir"

    restic restore "$snapshot_id" --target "$restore_dir" --tag "$service" --tag "database"

    # Find the dump file
    local dump_file=$(find "$restore_dir" -name "*.sql.gz" | head -1)

    if [ -z "$dump_file" ]; then
        echo -e "${RED}Error: Could not find dump file in snapshot${NC}"
        rm -rf "$restore_dir"
        exit 1
    fi

    # Decompress
    gunzip "$dump_file"
    dump_file="${dump_file%.gz}"

    # Drop and recreate database
    echo "Recreating database..."

    # Check which mysql client is available
    local mysql_cmd="mysql"
    if docker exec "$container" test -f /usr/bin/mariadb 2>/dev/null; then
        mysql_cmd="mariadb"
    elif docker exec "$container" which mariadb 2>/dev/null; then
        mysql_cmd="mariadb"
    fi

    docker exec "$container" "$mysql_cmd" -u"$user" -p"$password" -e "DROP DATABASE IF EXISTS $database;"
    docker exec "$container" "$mysql_cmd" -u"$user" -p"$password" -e "CREATE DATABASE $database;"
    docker exec -i "$container" "$mysql_cmd" -u"$user" -p"$password" "$database" < "$dump_file"

    # Cleanup
    rm -rf "$restore_dir"
}

# Restore volume
restore_volume() {
    local service=$1
    local snapshot_id=$2
    local volumes=$(parse_yaml_list "$service" "volumes")
    local compose=$(parse_yaml "$service" "compose_file")
    local compose_dir="$ROOT_DIR/$(dirname "$compose")"

    echo -e "${YELLOW}Stopping service...${NC}"
    (cd "$compose_dir" && docker compose down)

    # Create temporary restore directory
    local restore_dir="/tmp/restore_${service}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$restore_dir"

    # Restore snapshot to temp directory
    echo "Restoring snapshot to temporary location..."
    restic restore "$snapshot_id" --target "$restore_dir"

    # Restore each volume
    echo "$volumes" | while read vol; do
        echo "Restoring volume: $vol"

        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")

        if [ -z "$mountpoint" ]; then
            echo -e "${RED}Error: Volume $vol not found${NC}"
            continue
        fi

        echo "Volume mountpoint: $mountpoint"

        # Clear existing data
        echo "Clearing existing data..."
        rm -rf "${mountpoint:?}"/*
        rm -rf "${mountpoint:?}"/.[!.]*

        # Find the restored volume data in temp directory
        # Look for _data directory which contains the actual volume contents
        local volume_backup_path=$(find "$restore_dir" -type d -name "_data" | head -1)

        if [ -z "$volume_backup_path" ]; then
            echo -e "${YELLOW}Warning: Could not find _data directory, searching for volume name...${NC}"
            volume_backup_path=$(find "$restore_dir" -type d -path "*/$vol" | head -1)
        fi

        if [ -n "$volume_backup_path" ] && [ -d "$volume_backup_path" ]; then
            echo "Copying data from: $volume_backup_path"
            echo "Contents being copied:"
            ls -la "$volume_backup_path" | head -10

            # Copy all files and directories
            cp -a "$volume_backup_path"/* "$mountpoint/" 2>/dev/null || true
            cp -a "$volume_backup_path"/.[!.]* "$mountpoint/" 2>/dev/null || true

            # Verify copy
            echo "Verifying restore..."
            local copied_files=$(find "$mountpoint" -type f | wc -l)
            echo "Files copied: $copied_files"

            if [ "$copied_files" -eq 0 ]; then
                echo -e "${RED}Warning: No files found in volume after copy!${NC}"
            else
                echo -e "${GREEN}Data copied successfully${NC}"
            fi
        else
            echo -e "${RED}Error: Could not find volume data in snapshot${NC}"
            echo "Searched in: $restore_dir"
            echo "Directory structure:"
            find "$restore_dir" -type d | head -20
        fi
    done

    # Cleanup
    echo "Cleaning up temporary files..."
    rm -rf "$restore_dir"

    # Deliberately left stopped: cmd_restore still restores any additional
    # volumes/directories, then brings the stack back via redeploy_stack.
    echo -e "${YELLOW}Service left stopped until all restores finish...${NC}"
}

# Add new service
cmd_add() {
    local service=$1

    if grep -q "^  $service:" "$CONFIG_FILE"; then
        echo -e "${RED}Error: Service '$service' already exists${NC}"
        exit 1
    fi

    echo -e "${CYAN}=== Add New Service: $service ===${NC}\n"

    # Interactive prompts
    echo "Priority level?"
    echo "  1) critical (4x daily)"
    echo "  2) high (2x daily)"
    echo "  3) medium (daily)"
    echo "  4) low (weekly)"
    read -p "Choice [1-4]: " priority_choice

    case $priority_choice in
        1) priority="critical" ;;
        2) priority="high" ;;
        3) priority="medium" ;;
        4) priority="low" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac

    echo ""
    echo "Backup type?"
    echo "  1) postgres"
    echo "  2) mariadb"
    echo "  3) volume"
    echo "  4) directory"
    read -p "Choice [1-4]: " type_choice

    case $type_choice in
        1) type="postgres" ;;
        2) type="mariadb" ;;
        3) type="volume" ;;
        4) type="directory" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac

    echo ""
    read -p "Compose file path (relative to self-hosted/): " compose_file

    # Build YAML entry
    local entry="\n  $service:\n    priority: $priority\n    type: $type\n    compose_file: $compose_file\n"

    if [ "$type" = "postgres" ] || [ "$type" = "mariadb" ]; then
        read -p "Container name: " container
        read -p "Database name: " database
        read -p "Database user: " user
        entry="${entry}    container: $container\n    database: $database\n    user: $user\n"
    elif [ "$type" = "directory" ]; then
        read -p "Directory path (absolute): " directory
        entry="${entry}    directory: $directory\n"
    else
        read -p "Volume names (comma-separated): " volumes
        IFS=',' read -ra VOLUME_ARRAY <<< "$volumes"
        entry="${entry}    volumes:\n"
        for vol in "${VOLUME_ARRAY[@]}"; do
            vol=$(echo "$vol" | xargs) # trim whitespace
            entry="${entry}      - $vol\n"
        done
    fi

    read -p "Notes (optional): " notes
    [ -n "$notes" ] && entry="${entry}    notes: \"$notes\"\n"

    # Insert before the "# Restic Repository Configuration" line
    echo -e "$entry" | cat - <(echo "") >> "$CONFIG_FILE"

    echo -e "\n${GREEN}✓ Service '$service' added to config${NC}"
    echo -e "Run: ${CYAN}./backup-manager.sh backup $service${NC} to test"
}

# Main command dispatcher
main() {
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  list [priority]           - List all configured services"
        echo "  info <service>            - Show service backup configuration"
        echo "  backup <service>          - Backup a specific service"
        echo "  backup-all [priority]     - Backup all services"
        echo "  restore <service> [snap]  - Restore a service"
        echo "  snapshots <service>       - List snapshots"
        echo "  add <service>             - Add new service to config"
        echo "  sync-offsite              - Copy new snapshots to the offsite repository"
        echo "  maintenance               - Weekly retention + prune + check (both repos)"
        echo ""
        echo "Examples:"
        echo "  $0 list critical"
        echo "  $0 backup vaultwarden"
        echo "  $0 backup-all high"
        echo "  $0 restore authentik latest"
        echo "  $0 snapshots bookstack"
        exit 1
    fi

    local command=$1
    shift

    case "$command" in
        list)
            cmd_list "$@"
            ;;
        info)
            [ $# -lt 1 ] && { echo "Usage: $0 info <service>"; exit 1; }
            cmd_info "$@"
            ;;
        backup)
            [ $# -lt 1 ] && { echo "Usage: $0 backup <service>"; exit 1; }
            cmd_backup "$@"
            ;;
        backup-inner)
            # Internal: actual backup work, run as a child of cmd_backup
            [ $# -lt 1 ] && { echo "Usage: $0 backup <service>"; exit 1; }
            run_backup "$@"
            ;;
        backup-all)
            cmd_backup_all "$@"
            ;;
        sync-offsite)
            cmd_sync_offsite
            ;;
        maintenance)
            cmd_maintenance
            ;;
        maintenance-inner)
            # Internal: actual maintenance work, run as a child of cmd_maintenance
            run_maintenance
            ;;
        snapshots)
            [ $# -lt 1 ] && { echo "Usage: $0 snapshots <service>"; exit 1; }
            cmd_snapshots "$@"
            ;;
        restore)
            [ $# -lt 1 ] && { echo "Usage: $0 restore <service> [snapshot]"; exit 1; }
            cmd_restore "$@"
            ;;
        add)
            [ $# -lt 1 ] && { echo "Usage: $0 add <service>"; exit 1; }
            cmd_add "$@"
            ;;
        *)
            echo -e "${RED}Error: Unknown command: $command${NC}"
            exit 1
            ;;
    esac
}

main "$@"
