#!/bin/bash

# Import all .env files to a single Infisical project with separate folders per service

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="${SCRIPT_DIR}/../services"
ENVIRONMENT="prod" # Options: dev, staging, prod
LOG_FILE="${SCRIPT_DIR}/infisical-import-envs-$(date +%Y%m%d_%H%M%S).log"

# Create log file
echo "Infisical Migration Log - $(date)" > "$LOG_FILE"

log() {
    echo -e "$1"
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

log "${GREEN}==================================${NC}"
log "${GREEN}Infisical Import to Single Project${NC}"
log "${GREEN}Project ID: ${INFISICAL_PROJECT_ID}${NC}"
log "${GREEN}==================================${NC}"
log ""

# Check if Infisical CLI is installed
if ! command -v infisical &> /dev/null; then
    log "${RED}ERROR: Infisical CLI is not installed${NC}"
    exit 1
fi

# Check if logged in by testing access to the project
if ! infisical secrets folders get --path="/" --env="${ENVIRONMENT}" --projectId="${INFISICAL_PROJECT_ID}" &> /dev/null; then
    log "${YELLOW}Not logged in to Infisical or cannot access project. Please login first:${NC}"
    log "${YELLOW}  infisical login --domain=https://${INFISICAL_DOMAIN}${NC}"
    exit 1
fi

log "${GREEN}✓ Authenticated with Infisical${NC}"
log ""

# Function to create folder if it doesn't exist
create_folder() {
    local folder_name="$1"

    log "${BLUE}Creating folder: /${folder_name}${NC}"

    # Try to create the folder (it's okay if it already exists)
    result=$(infisical secrets folders create --name="${folder_name}" --path="/" --env="${ENVIRONMENT}" --projectId="${INFISICAL_PROJECT_ID}" 2>&1)

    if echo "$result" | grep -q -E "created|already exists"; then
        log "${GREEN}  ✓ Folder ready: /${folder_name}${NC}"
        return 0
    else
        log "${YELLOW}  ℹ ${result}${NC}"
        return 0
    fi
}

# Function to import secrets from .env file
import_secrets() {
    local env_file="$1"
    local folder_path="$2"
    local service_name="$3"

    log ""
    log "${BLUE}Importing secrets from: ${env_file}${NC}"
    log "${BLUE}To folder: ${folder_path}${NC}"

    # Count secrets for display
    local secret_count=$(grep -cE '^[^#].*=' "$env_file" 2>/dev/null || echo "0")

    # Create a temporary file with escaped variable references
    local temp_file="/tmp/infisical-import-${service_name}.env"
    sed 's/\${/\$\${/g' "$env_file" > "$temp_file"

    # Import entire file at once using --file flag
    set +e
    if infisical secrets set --file="${temp_file}" \
        --env="${ENVIRONMENT}" \
        --projectId="${INFISICAL_PROJECT_ID}" \
        --path="${folder_path}" > /dev/null 2>&1; then
        log "${GREEN}  ✓ Imported ${secret_count} secrets successfully${NC}"
    else
        log "${RED}  ✗ Failed to import secrets - trying line by line...${NC}"
        # Fallback: import line by line if bulk import fails
        import_secrets_line_by_line "$env_file" "$folder_path"
    fi
    set -e

    # Clean up temp file
    rm -f "$temp_file"
}

# Fallback function for line-by-line import
import_secrets_line_by_line() {
    local env_file="$1"
    local folder_path="$2"

    local imported=0
    local failed=0

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Parse KEY=VALUE
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            # Remove quotes if present
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

            # Import using Infisical CLI
            if infisical secrets set "${key}=${value}" \
                --env="${ENVIRONMENT}" \
                --projectId="${INFISICAL_PROJECT_ID}" \
                --path="${folder_path}" \
                --silent > /dev/null 2>&1; then
                echo "  ✓ ${key}"
                ((imported++))
            else
                echo "  ✗ ${key}"
                ((failed++))
            fi
        fi
    done < "$env_file"

    log "${GREEN}  Summary: ${imported} imported, ${failed} failed${NC}"
}

# Main migration process
log "${YELLOW}Scanning for .env files...${NC}"
mapfile -t env_files < <(find "${SERVICES_DIR}" -name ".env" -type f | sort)

if [ ${#env_files[@]} -eq 0 ]; then
    log "${RED}No .env files found in ${SERVICES_DIR}${NC}"
    exit 1
fi

log "${GREEN}Found ${#env_files[@]} .env files${NC}"
log ""

# Display summary
log "${YELLOW}Services to migrate:${NC}"
for env_file in "${env_files[@]}"; do
    service_name=$(basename $(dirname "$env_file"))
    secret_count=$(grep -cE '^[^#].*=' "$env_file" 2>/dev/null || echo "0")
    log "  • ${service_name}: ${secret_count} secrets → /${service_name}"
done

log ""
read -p "Proceed with import to project ${INFISICAL_PROJECT_ID}? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "${YELLOW}Import cancelled${NC}"
    exit 0
fi

log ""
log "${GREEN}Starting import process...${NC}"
log ""

# Process each service
for env_file in "${env_files[@]}"; do
    service_name=$(basename $(dirname "$env_file"))
    folder_path="/${service_name}"

    log "${YELLOW}=====================================${NC}"
    log "${YELLOW}Processing: ${service_name}${NC}"
    log "${YELLOW}=====================================${NC}"

    # Create folder for this service
    create_folder "$service_name"

    # Import secrets
    import_secrets "$env_file" "$folder_path" "$service_name"

    log ""
done

log ""
log "${GREEN}==================================${NC}"
log "${GREEN}Import Complete!${NC}"
log "${GREEN}==================================${NC}"
log ""
log "${YELLOW}Summary:${NC}"
log "  Project ID: ${INFISICAL_PROJECT_ID}"
log "  Environment: ${ENVIRONMENT}"
log "  Services imported: ${#env_files[@]}"
log ""
log "${YELLOW}Next Steps:${NC}"
log "  1. Verify secrets at: https://${INFISICAL_DOMAIN}"
log "  2. Navigate to your project"
log "  3. Check each folder (${#env_files[@]} folders created)"
log "  4. Update docker-compose files to use Infisical"
log ""
log "${YELLOW}Log saved to: ${LOG_FILE}${NC}"
log ""
