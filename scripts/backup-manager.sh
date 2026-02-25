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

    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD
    export B2_ACCOUNT_ID
    export B2_ACCOUNT_KEY
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

    if [ -z "${APPRISE_URL:-}" ]; then
        echo -e "${YELLOW}Warning: APPRISE_URL not set, skipping notification${NC}"
        return 0
    fi

    local logs_link="${GRAFANA_LOGS_URL:-https://grafana.yourdomain.com}"
    body+="\n\n[View Backup Logs]($logs_link)"

    # Send notification using apprise CLI or curl
    if command -v apprise &> /dev/null; then
        echo "$body" | apprise -t "$title" -b - "$APPRISE_URL" --tag "$type"
    else
        # Fallback to curl if apprise CLI is not installed
        curl -X POST "$APPRISE_URL/notify/$APPRISE_CONFIG?tags=backups" \
            -u "$APPRISE_LOGIN" \
            -H "Content-Type: application/json" \
            -d "{\"title\": \"$title\", \"body\": \"$body\", \"type\": \"$type\"}" \
            --silent --show-error || echo -e "${YELLOW}Warning: Failed to send notification${NC}"
    fi
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

# Backup a service
cmd_backup() {
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
        # Try common password variable names
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|POSTGRES_PASSWORD|${database^^}_PASSWORD|DATABASE_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"')
    fi

    if [ -z "$password" ]; then
        echo -e "${YELLOW}Warning: Could not find password in .env, trying without password${NC}"
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
        --tag "$database"

    rm "${dump_file}.gz"

    # Apply retention policy
    apply_retention "$service"
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
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|MYSQL_PASSWORD|MARIADB_PASSWORD|${database^^}_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"')
    fi

    if [ -z "$password" ]; then
        echo -e "${RED}Error: Could not find MariaDB password${NC}"
        exit 1
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
        --tag "$database"

    rm "${dump_file}.gz"

    # Apply retention policy
    apply_retention "$service"
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

    # Apply retention policy
    apply_retention "$service"
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
        --tag "$volume"
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
        --tag "$(basename "$directory")"

    # Apply retention policy
    apply_retention "$service"
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
        --tag "$(basename "$dir")"
}

# Apply retention policy
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
        --keep-monthly "$monthly" \
        --prune
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

# Restore service
cmd_restore() {
    local service=$1
    local snapshot_id=${2:-}

    if ! grep -q "^  $service:" "$CONFIG_FILE"; then
        echo -e "${RED}Error: Service '$service' not found in config${NC}"
        exit 1
    fi

    local type=$(parse_yaml "$service" "type")

    # If no snapshot specified, show available snapshots and prompt
    if [ -z "$snapshot_id" ]; then
        echo -e "${CYAN}Available snapshots for $service (type: $type):${NC}\n"

        # Filter snapshots by type
        if [ "$type" = "postgres" ] || [ "$type" = "mariadb" ]; then
            restic snapshots --tag "$service" --tag "database"
        else
            restic snapshots --tag "$service" --tag "volume"
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

    local type=$(parse_yaml "$service" "type")

    case "$type" in
        postgres)
            restore_postgres "$service" "$snapshot_id"
            ;;
        mariadb)
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

    # Restore additional volumes if specified
    local volumes_also=$(parse_yaml_list "$service" "volumes_also")
    if [ -n "$volumes_also" ]; then
        echo -e "\n${CYAN}Restoring additional volumes...${NC}"

        # Get latest volume snapshot for this service
        local volume_snapshot=$(restic snapshots --tag "$service" --tag "volume" --json | jq -r '.[-1].short_id')

        if [ -n "$volume_snapshot" ] && [ "$volume_snapshot" != "null" ]; then
            echo "Using volume snapshot: $volume_snapshot"

            # Create temporary restore directory
            local restore_dir="/tmp/restore_${service}_volumes_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$restore_dir"

            # Restore snapshot to temp directory
            echo "Restoring volume snapshot..."
            restic restore "$volume_snapshot" --target "$restore_dir"

            # Restore each additional volume
            echo "$volumes_also" | while read vol; do
                echo "Restoring additional volume: $vol"

                local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")

                if [ -z "$mountpoint" ]; then
                    echo -e "${YELLOW}Warning: Volume $vol not found, skipping${NC}"
                    continue
                fi

                echo "Volume mountpoint: $mountpoint"

                # Clear existing data
                echo "Clearing existing data..."
                rm -rf "${mountpoint:?}"/*
                rm -rf "${mountpoint:?}"/.[!.]*

                # Find the restored volume data
                local volume_backup_path=$(find "$restore_dir" -type d -name "_data" | grep "$vol" | head -1)

                if [ -z "$volume_backup_path" ]; then
                    volume_backup_path=$(find "$restore_dir" -type d -name "_data" | head -1)
                fi

                if [ -n "$volume_backup_path" ] && [ -d "$volume_backup_path" ]; then
                    echo "Copying data from: $volume_backup_path"
                    cp -a "$volume_backup_path"/* "$mountpoint/" 2>/dev/null || true
                    cp -a "$volume_backup_path"/.[!.]* "$mountpoint/" 2>/dev/null || true

                    local copied_files=$(find "$mountpoint" -type f | wc -l)
                    echo "Files copied: $copied_files"
                else
                    echo -e "${YELLOW}Warning: Could not find volume data for $vol${NC}"
                fi
            done

            # Cleanup
            rm -rf "$restore_dir"
        else
            echo -e "${YELLOW}Warning: No volume snapshots found for additional volumes${NC}"
        fi
    fi

    # Restore additional directories if specified
    local dirs_also=$(parse_yaml_list "$service" "directories_also")
    if [ -n "$dirs_also" ]; then
        echo -e "\n${CYAN}Restoring additional directories...${NC}"

        # Get latest directory snapshot for this service
        local dir_snapshot=$(restic snapshots --tag "$service" --tag "directory" --json | jq -r '.[-1].short_id')

        if [ -n "$dir_snapshot" ] && [ "$dir_snapshot" != "null" ]; then
            echo "Using directory snapshot: $dir_snapshot"

            # Create temporary restore directory
            local restore_dir="/tmp/restore_${service}_dirs_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$restore_dir"

            # Restore snapshot to temp directory
            echo "Restoring directory snapshot..."
            restic restore "$dir_snapshot" --target "$restore_dir"

            # Restore each additional directory
            echo "$dirs_also" | while read dir; do
                echo "Restoring additional directory: $dir"

                local target_path="$ROOT_DIR/$dir"

                # Create parent directory if it doesn't exist
                mkdir -p "$(dirname "$target_path")"

                # Find the restored directory data
                local dir_backup_path=$(find "$restore_dir" -type d -path "*/$dir" | head -1)

                if [ -z "$dir_backup_path" ]; then
                    # Try finding by basename
                    local dir_basename=$(basename "$dir")
                    dir_backup_path=$(find "$restore_dir" -type d -name "$dir_basename" | head -1)
                fi

                if [ -n "$dir_backup_path" ] && [ -d "$dir_backup_path" ]; then
                    echo "Copying data from: $dir_backup_path"
                    echo "To: $target_path"

                    # Clear existing data
                    rm -rf "$target_path"

                    # Copy the directory
                    cp -a "$dir_backup_path" "$target_path"

                    local copied_files=$(find "$target_path" -type f 2>/dev/null | wc -l)
                    echo "Files copied: $copied_files"
                else
                    echo -e "${YELLOW}Warning: Could not find directory data for $dir${NC}"
                    echo "Searched in: $restore_dir"
                fi
            done

            # Cleanup
            rm -rf "$restore_dir"
        else
            echo -e "${YELLOW}Warning: No directory snapshots found${NC}"
        fi
    fi

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
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|POSTGRES_PASSWORD|${database^^}_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"')
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
        password=$(grep -E "^(DB_PASS|DB_PASSWORD|MYSQL_PASSWORD|MARIADB_PASSWORD)" "$compose_dir/.env" | cut -d'=' -f2- | head -1 | tr -d '"')
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

    echo -e "${YELLOW}Starting service...${NC}"
    (cd "$compose_dir" && docker compose up -d)
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
        backup-all)
            cmd_backup_all "$@"
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
