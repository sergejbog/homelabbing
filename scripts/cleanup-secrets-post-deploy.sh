#!/bin/bash

# Post-deploy script: Clean up .env file after deployment
# Usage: ./cleanup-secrets-post-deploy.sh [service-name]

SERVICE_NAME="${1:-komodo}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_PATH="${SCRIPT_DIR}/../services/${SERVICE_NAME}"
ENV_FILE="${SERVICE_PATH}/.env"

echo "🧹 Cleaning up secrets for ${SERVICE_NAME}..."

if [ -f "${ENV_FILE}" ]; then
    # Create backup before deletion (optional)
    # cp "${ENV_FILE}" "${ENV_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Remove the .env file
    rm -f "${ENV_FILE}"
    echo "✅ Secrets cleaned up: ${ENV_FILE}"
else
    echo "ℹ️  No .env file found to clean up"
fi
